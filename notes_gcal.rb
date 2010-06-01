require 'rubygems'
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
    p "logged into Lotus Notes"
    
    self.class.headers "Cookie" => cookie
    self.class.base_uri @mail_file_url
    response = self.class.get(CALENDAR_PATH)
  
    events = []
  
    response['viewentries']['viewentry'].each do |e|
      
      id = e['unid']

      subject = e['entrydata'].select {|x| x['name'] == "$147"}[0]['textlist']['text'][0] rescue nil
      location = e['entrydata'].select {|x| x['name'] == "$147"}[0]['textlist']['text'][1] rescue nil
      
      # this index might be 3 if there is a callin number separate-- size=4
      # host = e['entrydata'].select {|x| x['name'] == "$147"}[0]['textlist']['text'][2] rescue nil
      
      start_str = e['entrydata'].select {|x| x['name'] == "$144"}[0]['datetime']
      start_str = e['entrydata'].select {|x| x['name'] == "$144"}[0]['datetimelist']['datetime'] if start_str.nil? 
      starttime = parse_datetime(start_str)
      
      end_str = e['entrydata'].select {|x| x['name'] == "$146"}[0]['datetime']
      end_str = e['entrydata'].select {|x| x['name'] == "$146"}[0]['datetimelist']['datetime'] if end_str.nil?
      endtime = parse_datetime(end_str)
      
      
      events << {:id => id+start_str, :subject => subject, :start => starttime, :end => endtime, :location => location}
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
    # p "@cal = #{@cal}"
    e = Event.new(@service, {:calendar => @cal, :title => event[:subject], :start_time => event[:start], :end_time => event[:end], :where => event[:location]})
    e.reminder = [{:minutes => 10, :method => :alert}]
    e.save
    e
  end
  
  def update_event(gevent, event)
    gevent.title = event[:subject]
    gevent.start_time = event[:start]
    gevent.end_time   = event[:end]
    gevent.where = event[:location]
    # gevent.reminder = [{:minutes => 10, :method => :alert}]
    gevent.save
  end
  
  def set_calendar(calendar_name)
    @cal = Calendar.find(@service, calendar_name, :scope => :first)
    @cal = @cal[0] if @cal.is_a? Array
    p "selected calendar #{@cal}" if !@cal.nil? 
  end
  
  def initialize(username, password)
    @service = Service.new
    # @service.debug = true
    @service.authenticate(username, password)
    p "logged into google calendar"
  end
  
  def find(event_id)
    Event.find(@service, {:id => event_id})
  end
  
  def events
    Event.find(@service, "", :range => {:start => Time.now - (60*60*24*90), :end => Time.now + (60*60*24*90)})
  end
  
  
  def delete_all
    count = 0
    @cal.events.each do |e|
      title = e.title
      count += 1 if e.delete
    end
    p "deleted #{count} events"
  end

end

def sync(calendar, notes_events, cache)
  
  notes_events.each do |ne|

    gevent = cache.key?(ne[:id]) ? calendar.find(cache[ne[:id]]) : nil
    
    if gevent != [] and !gevent.nil?
      calendar.update_event(gevent, ne)
      p "updated event #{gevent.title}"
    else
      e = calendar.create_event(ne)
      cache[ne[:id]] = e.id
      p "created event #{e.title}"
    end
  end
  
  flush_cache(cache)
end


def overwrite_all(calendar, notes_events)

  calendar.delete_all
  calendar.delete_all
  # p "deleted all events from google calendar"
  cache = {}
     
   notes_events.each do |ne|
     e = calendar.create_event(ne)
     cache[ne[:id]] = e.id
     p "created event #{e.title}"
   end
   
   # p cache
   flush_cache(cache)
  
end

# write the cache to disk
def flush_cache(cache)
  File.open(CACHE_FILE, 'w') do |out|
    YAML.dump(cache, out)
  end
end


notes = NotesCalendar.new(NOTES_MAIL_FILE, NOTES_USERNAME, NOTES_PASSWORD)
gcal = GoogleCalendar.new(GOOGLE_USERNAME, GOOGLE_PASSWORD)
gcal.set_calendar(GOOGLE_CALENDAR_NAME)

cache = YAML::load(File.read(CACHE_FILE)) rescue {}
sync(gcal, notes.events, cache)
# overwrite_all(gcal,notes.events)


