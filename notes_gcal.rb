require 'rubygems'
require "bundler/setup"

require 'net/http'
require 'uri'
require 'httparty'
require 'yaml'
require 'gcal4ruby'


CACHE_FILE = File.join(File.dirname(__FILE__), "/gcalcache.yml")
data_file = File.join(File.dirname(__FILE__), "/config.yml")
@config   = YAML::load(File.read(data_file)) rescue {}

NOTES_MAIL_FILE = @config['notes_mail_file']
NOTES_USERNAME = @config['notes_username']
NOTES_PASSWORD = @config['notes_password']
GOOGLE_USERNAME = @config['google_username']
GOOGLE_PASSWORD = @config['google_password']
GOOGLE_CALENDAR_NAME = @config['google_calendar_name']


class NotesCalendar
  include HTTParty
  
  CALENDAR_PATH = "/($calendar)?ReadViewEntries#&KeyType=time&count=9999&StartKey=" + (Date.today<<3).strftime("%Y%m%d") + "&UntilKey=" + (Date.today>>3).strftime("%Y%m%d")
  
  def initialize(mail_file_url, username, password)
    @mail_file_url = mail_file_url
    @username = username
    @password = password
  end
  
  def events
    url = URI.parse(@mail_file_url)
    req = Net::HTTP.new(url.host, url.port)
    response=req.post(@mail_file_url + "/?Login", "username=#{@username}&password=#{@password}")

    cookie = response["Set-Cookie"]
    log("logged into Lotus Notes")
    
    self.class.headers "Cookie" => cookie
    self.class.base_uri @mail_file_url
    response = self.class.get(CALENDAR_PATH)
  
    events = []
    
    File.open("/tmp/notescal.xml", "w") do |file|
      file.write(response);
    end
    
    response['viewentries']['viewentry'].each do |e|
      begin
        id = e['unid']

        subject = e['entrydata'].select {|x| x['name'] == "$147"}[0]['textlist']['text'][0] rescue nil
        location = e['entrydata'].select {|x| x['name'] == "$147"}[0]['textlist']['text'][1] rescue nil
      
        # log(e['entrydata']) if subject == nil
        subject = e['entrydata'].select {|x| x['name'] == "$147"}[0]['text'] if subject.nil?
      
        # this index might be 3 if there is a callin number separate-- size=4
        # host = e['entrydata'].select {|x| x['name'] == "$147"}[0]['textlist']['text'][2] rescue nil
      
        start_str = e['entrydata'].select {|x| x['name'] == "$144"}[0]['datetime'] rescue nil
        start_str = e['entrydata'].select {|x| x['name'] == "$144"}[0]['datetimelist']['datetime'] rescue nil if start_str.nil? 

        # maybe it's an all day event?
        if start_str.nil? 
          start_str = e['entrydata'].select {|x| x['name'] == "$134"}[0]['datetime'] rescue nil
          start_str = e['entrydata'].select {|x| x['name'] == "$134"}[0]['datetimelist']['datetime'] rescue nil if start_str.nil?
          
          all_day = true
        end
        
        #give up if we still don't have a time
        raise RuntimeError if start_str.nil? 

        starttime = parse_datetime(start_str)
    
        if all_day === true
          endtime = starttime
        else
          end_str = e['entrydata'].select {|x| x['name'] == "$146"}[0]['datetime']
          end_str = e['entrydata'].select {|x| x['name'] == "$146"}[0]['datetimelist']['datetime'] if end_str.nil?
          endtime = parse_datetime(end_str)
        end
      
        events << {:id => id+start_str, :subject => subject, :start => starttime, :end => endtime, :location => location, :all_day => all_day}
      rescue Exception => exc
        log(exc)
        log(exc.backtrace)
        log(e)
        quit
      end
    end
    
    events
  end
  
  def parse_datetime(ndate)
    date = Date.parse(ndate[0...8]).to_s
    time = ndate[9...11] + ":" + ndate[11...13]
    
    timezone = case ndate[18...21]
    when "-08"
      "PST"
    when "-07"
      "PDT"
    when "-05"
      "EST"
    when "-04"
      "EDT"
    end
    timestring = "#{date} #{time} #{timezone}"
    Time.parse(timestring)
  end
    
end

class GoogleCalendar
  include GCal4Ruby
  
  def create_event(event)
    e = Event.new(@service, {:calendar => @cal, :title => event[:subject], :start_time => event[:start], :end_time => event[:end], :where => event[:location]})
    e.all_day = true if event[:all_day] === true
    e.reminder = [{:minutes => 10, :method => 'alert'}]
    e.save
    e
  end
  
  def update_event(gevent, event)
    gevent.title = event[:subject]
    gevent.start_time = event[:start]
    gevent.end_time   = event[:end]
    gevent.where = event[:location]
    gevent.all_day = event[:all_day]
    # gevent.reminder = [{:minutes => 10, :method => :alert}]
    gevent.save
  end
  
  def set_calendar(calendar_name)
    @cal = Calendar.find(@service, calendar_name, :scope => :first)
    @cal = @cal[0] if @cal.is_a? Array
    log("selected calendar: #{@cal.title}") if !@cal.nil?
  end
  
  def initialize(username, password)
    @service = Service.new
    # @service.debug = true
    @service.authenticate(username, password)
    log("logged into google calendar")
  end
  
  def find(event_id)
    Event.find(@service, {:id => event_id})
  end
  
  def events
    Event.find(@service, "", {'start-min' => (Time.now - (60*60*24*90)).utc.xmlschema, 'start-max' => (Time.now + (60*60*24*90)).utc.xmlschema, :calendar => @cal.id, 'max-results' => 200})
  end
  
  
  def delete_all
    count = 0
    @cal.events.each do |e|
      title = e.title
      begin
        count += 1 if e.delete
      rescue Exception => e
        log("something went wrong")
        log(e)
      end
    end
    log("deleted #{count} events")
  end

end

def sync(calendar, notes_events, cache)
  
  count_notes_events = 0
  count_new = 0
  count_updated = 0
  count_deleted = 0
  
  
  new_cache = {}
  
  notes_events.each do |notesevent|
        
    gevent = cache.key?(notesevent[:id]) ? calendar.find(cache[notesevent[:id]][:gcal_id]) : nil
         
    if gevent != [] and !gevent.nil? 

       cached_event_without_gcal_id = cache[notesevent[:id]].reject {|key, value| key == :gcal_id}

       # only update if the event has changed
       if !notesevent.eql?(cached_event_without_gcal_id)
         calendar.update_event(gevent, notesevent)
         log("updated event #{gevent.title}")
         count_updated += 1
       end 
         
       new_cache[notesevent[:id]] = notesevent.merge({:gcal_id => gevent.id})
       
     else
       new_gevent = calendar.create_event(notesevent)
       new_cache[notesevent[:id]] = notesevent.merge({:gcal_id => new_gevent.id})
       log("created new event: #{new_gevent.title}")
       count_new += 1
     end
     count_notes_events += 1
   end
  
  calendar.events.each do |googleevent|

    if (new_cache.values.select {|c| c[:gcal_id] == googleevent.id}.size == 0 and 
      googleevent.start_time >= Time.now and 
      cache.values.select {|c| c[:gcal_id] == googleevent.id}.size > 0)
      
      log("looks like event #{googleevent.title} - #{googleevent.start_time} in #{googleevent.calendar.title} was deleted! deleting it....")
      googleevent.delete
      count_deleted += 1
    end
  end
  
  print "done! For #{count_notes_events} events in Notes, we:\ncreated: #{count_new}\nupdated: #{count_updated}\ndeleted: #{count_deleted}\n"
  
  flush_cache(new_cache)
end


def overwrite_all(calendar, notes_events)

  calendar.delete_all
  calendar.delete_all
  log("deleted all events from google calendar")
  cache = {}
     
   notes_events.each do |notesevent|
     new_gevent = calendar.create_event(notesevent)
     cache[notesevent[:id]] = notesevent.merge({:gcal_id => new_gevent.id})
     log("created event #{new_gevent.title}")
   end

   flush_cache(cache)
  
end

# write the cache to disk
def flush_cache(cache)
  File.open(CACHE_FILE, 'w') do |out|
    YAML.dump(cache, out)
  end
end

def log(msg)
  p "#{Time.now} | #{msg}"
end

notes = NotesCalendar.new(NOTES_MAIL_FILE, NOTES_USERNAME, NOTES_PASSWORD)
gcal = GoogleCalendar.new(GOOGLE_USERNAME, GOOGLE_PASSWORD)
gcal.set_calendar(GOOGLE_CALENDAR_NAME)

cache = YAML::load(File.read(CACHE_FILE)) rescue {}

# uncomment to wipe out the whole calendar
# overwrite_all(gcal,notes.events)

sync(gcal, notes.events, cache)



