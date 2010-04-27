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
    p "successfully logged into Lotus Notes"
    
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
      
      events << {:id => id, :subject => subject, :start => starttime, :end => endtime, :location => location}
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

  def calendar(calendar_name)
    cal = GCal4Ruby::Calendar.find(@service, calendar_name, :scope => :first)
  end
  
  def initialize(username, password)
    @service = GCal4Ruby::Service.new
    @service.authenticate(username, password)
    p "logged into google calendar"
  end

end

def sync(calendar, notes_events, cache)
  
  notes_events.each do |ne|
    if cache.key?(ne[:id])
      event = GCal4Ruby::Event.find(calendar, cache[ne[:id]])
      event.title = ne[:subject]
      event.start = ne[:start]
      event.end   = ne[:end]
      event.where = ne[:location]
      event.save
      p "updated event #{event.title}"
    else
      e = GCal4Ruby::Event.new(calendar, {:title => ne[:subject], :start => ne[:start], :end => ne[:end], :where => ne[:location]})
      e.save
      cache[ne[:id]] = e.id
      p "created event #{e.title}"
    end
  end
  
  flush_cache(cache)
end



def overwrite_all(calendar, notes_events)

  calendar.events.each do |e|
    p "deleting event #{e.title}"
    if e.delete
      e.save
      p "deleted event"
    else
      p "couldn't delete event"
    end
  end
  
  p "deleted all events from google calendar"
  # cache = {}

  notes_events.each do |ne|
    e = GCal4Ruby::Event.new(calendar, {:title => ne[:subject], :start => ne[:start], :end => ne[:end], :where => ne[:location]})
    e.save
    cache[ne[:id]] = e.id
    p "created event #{e.title}"
  end
  
  p cache
  flush_cache(cache)
  
end

# write the cache to disk
def flush_cache(cache)
  File.open(CACHE_FILE, 'w') do |out|
    YAML.dump(cache, out)
  end
end


notes = NotesCalendar.new(NOTES_MAIL_FILE, NOTES_USERNAME, NOTES_PASSWORD)
gcal = GoogleCalendar.new(GOOGLE_USERNAME, GOOGLE_PASSWORD).calendar(GOOGLE_CALENDAR_NAME)

cache = YAML::load(File.read(CACHE_FILE)) rescue {}
sync(gcal, notes.events, cache)

