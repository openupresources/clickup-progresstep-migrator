#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'yaml'
require 'uri'

class ClickUpTaskMigrator
  # Mapping from Progress Step values to status names
  PROGRESS_STEP_MAPPING = {
    0 => 'WAITING',
    1 => 'RESEARCH', 
    2 => 'EXECUTION',
    3 => 'REVIEW',
    4 => 'TESTING',
    5 => 'ACCEPTED'
  }.freeze

  def initialize
    @config = load_config
    @api_token = @config['api_token']
    @space_id = @config['space_id']
    @base_url = 'https://api.clickup.com/api/v2'
    
    @headers = {
      'Authorization' => @api_token,
      'Content-Type' => 'application/json'
    }
    validate_config
  end

  def migrate_tasks
    puts "Starting migration for space #{@space_id}..."
    
    tasks = get_all_tasks_in_space(@space_id)
   
    # Find the Progress Step custom field
    progress_step_field = find_progress_step_field(tasks)
    return unless progress_step_field
    
    # Get available statuses for the space
  #  statuses = fetch_space_statuses
  #  status_map = create_status_map(statuses)

    # Process each task
    migration_count = 0
    tasks.each_with_index do |task, index|
      puts "Processing task #{index + 1}/#{tasks.length}: #{task['name']}"
      
      if migrate_single_task(task, progress_step_field)
        migration_count += 1
      end
      
      # Add small delay to avoid rate limiting
      sleep(0.1)
    end
    
    puts "\nMigration completed!"
    puts "Successfully migrated #{migration_count} tasks"
  end

  # Get all tasks from a specific space
  def get_all_tasks_in_space(space_id)
    print "Getting all tasks in space #{@space_id}...\n"    
    all_tasks = []
    
    # First, get all folders in the space
    folders = get_folders(space_id)
    
    # Get tasks from folderless lists in the space
    folderless_lists = get_folderless_lists(space_id)
    folderless_lists.each do |list|
      tasks = get_tasks_from_list(list['id'])
      all_tasks.concat(tasks)
    end
    
    # Get tasks from folders
    folders.each do |folder|
      lists = get_lists_in_folder(folder['id'])
      lists.each do |list|
        tasks = get_tasks_from_list(list['id'])
        all_tasks.concat(tasks)
      end
    end
    
    all_tasks
  end

  def get_folders(space_id)
    print "Getting folders in space #{@space_id}...\n"
    response = make_request("/space/#{@space_id}/folder")
    response ? response['folders'] : []
  end
  
  def get_folderless_lists(space_id)
    print "Getting folderless lists in space #{@space_id}...\n"
    response = make_request("/space/#{@space_id}/list")
    response ? response['lists'] : []
  end
  
  def get_lists_in_folder(folder_id)
    print "Getting lists in folder #{folder_id}...\n "
    response = make_request("/folder/#{@folder_id}/list")
    response ? response['lists'] : []
  end
  
  def get_tasks_from_list(list_id)
    all_tasks = []
    page = 0

    print "Getting tasks from list #{list_id}...\n"
    
    loop do
      response = make_request("/list/#{list_id}/task?page=#{page}")
      break unless response && response['tasks']
      
      tasks = response['tasks']
      break if tasks.empty?
      
      all_tasks.concat(tasks)
      page += 1
      
      # Break if we've gotten all tasks (less than 100 returned means we're done)
      break if tasks.length < 100
    end
    
    all_tasks
  end

private

  def load_config
    config_file = 'clickup_config.yml'
    unless File.exist?(config_file)
      raise "Configuration file '#{config_file}' not found"
    end
    
    YAML.load_file(config_file)
  rescue Psych::SyntaxError => e
    raise "Invalid YAML in configuration file: #{e.message}"
  end

  def validate_config
    raise "Missing 'api_token' in configuration" unless @api_token
    raise "Missing 'space_id' in configuration" unless @space_id
    
    puts "Configuration loaded successfully"
    puts "Space ID: #{@space_id}"
  end

  def fetch_all_tasks
    print "Fetching all tasks in space #{@space_id}... \n"
    uri = URI("#{@base_url}/space/#{@space_id}/task")
    uri.query = URI.encode_www_form({
      'include_closed' => true,
      'page' => 0,
      'order_by' => 'created',
      'reverse' => false,
      'subtasks' => true,
      'statuses' => 'all',
      'include_markdown_description' => false
    })

    print uri.to_s + "\n"  # Debug: show the request URL
    response = make_api_request(uri)
    
    if response.code == '200'
      data = JSON.parse(response.body)
      data['tasks'] || []
    else
      raise "Failed to fetch tasks: #{response.code} - #{response.body}"
    end
  end

  def find_progress_step_field(tasks)
    # Look through tasks to find the Progress Step custom field
    tasks.each do |task|
      next unless task['custom_fields']
      
      task['custom_fields'].each do |field|
        if field['name']&.downcase == 'progress step'
          puts "Found Progress Step field with ID: #{field['id']}"
          return field
        end
      end
    end
    
    puts "Warning: No 'Progress Step' custom field found in any tasks"
    nil
  end

  def fetch_space_statuses
    puts "Trying to get statuses for space #{@space_id}"
    response = make_request("/space/#{@space_id}")

    data = JSON.parse(response.to_json)


    # Extract all statuses from all lists in the space
    statuses = []
    puts data.to_s+"...\n"
    puts "Pulling from json to get statuses...\n"
    # Get statuses from lists
    data.each do |list|
      puts "Interating through list: #{list}\n"
      list['statuses'].each do |status|
        statuses << status
         puts "Status: #{status}\n"
      end
    end
    
    statuses.uniq { |s| s['status'] }
   
    statuses
  end

  def fetch_statuses_from_lists
    # Get folders and lists to find statuses
    response = make_request("/space/#{@space_id}/list")
    
    if response.code == '200'
      data = JSON.parse(response.body)
      statuses = []
      
      data['lists']&.each do |list|
        list['statuses']&.each do |status|
          statuses << status
        end
      end
      
      statuses.uniq { |s| s['status'] }
    else
      raise "Failed to fetch lists and statuses: #{response.code} - #{response.body}"
    end
  end

  def create_status_map(statuses)
    status_map = {}
    
    PROGRESS_STEP_MAPPING.each do |step_value, target_status|
      # Find matching status (case insensitive)
      matching_status = statuses.find do |status|
        status['status']&.downcase == target_status.downcase
      end
      
      if matching_status
        status_map[step_value] = matching_status['status']
        puts "Mapped Progress Step #{step_value} -> Status '#{matching_status['status']}'"
      else
        puts "Warning: No status found for '#{target_status}' (Progress Step #{step_value})"
      end
    end
    
    status_map
  end

  def migrate_single_task(task, progress_step_field)
    return false unless task['custom_fields']
    
    # Find the current Progress Step value for this task
    current_progress_step = nil
    task['custom_fields'].each do |field|
      if field['id'] == progress_step_field['id']
        current_progress_step = field['value']
        puts "  ↳ Current Progress Step: #{current_progress_step}\n"
        break
      end
    end
    
    return false unless current_progress_step

    # Convert to integer if it's a string
    step_value = current_progress_step.is_a?(String) ? current_progress_step.to_i : current_progress_step
    
    target_status = PROGRESS_STEP_MAPPING[step_value]#status_map[step_value]

    #return false unless target_status  

    # Skip if already at target status
    if task['status']['status'] == target_status
      puts "  ↳ Already at correct status (#{target_status})"
      return false
    end
    
    # Update the task status
    update_task_status(task['id'], target_status)
  end

  def update_task_status(task_id, status)
    print "updating task #{task_id} to status #{status}... \n"
    
    uri = URI("#{@base_url}/task/#{task_id}")
    
    request_body = { status: status }.to_json
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Put.new(uri)
    request['Authorization'] = @api_token
    request['Content-Type'] = 'application/json'
    request.body = request_body
    
    response = http.request(request)
    
    if response.code == '200'
      puts "  ↳ Updated to status: #{status}"
      true
    else
      puts "  ↳ Failed to update status: #{response.code} - #{response.body}"
      false
    end
  end

  def make_api_request_old(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = @api_token
    request['Content-Type'] = 'application/json'
    
    http.request(request)
  end

  def make_request(endpoint)
    
    uri = URI("#{@base_url}#{endpoint}")
    puts "Making request to: #{uri}\n"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = @api_token
    request['Content-Type'] = 'application/json'
    request['User-Agent'] = 'ClickUp Task Migration'
    
    response = http.request(request)
    
    if response.code == '200'
      JSON.parse(response.body)
    else
      puts "Error: #{response.code} - #{response.body} - while accessing #{uri.to_s}\n"
      nil
    end
  end

  def make_api_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = @api_token
    request['Content-Type'] = 'application/json'
    request['User-Agent'] = 'ClickUp Task Migration'
    
    http.request(request)
  end
  
end



# Run the migration
if __FILE__ == $0
  begin
    migrator = ClickUpTaskMigrator.new
    migrator.migrate_tasks
  rescue => e
    puts "Error: #{e.message}"
    puts e.backtrace if ENV['DEBUG']
    exit 1
  end
end