use 5.018;
use utf8;
use threads;
use threads::shared;
use Thread::Queue;
use File::Copy;
use FindBin;
use Time::HiRes qw/time/;
use HTML::Entities;
use IO::File;
use Data::Dumper;
use LWP::Simple;
use MongoDB;
use MongoDB::OID;
use Getopt::Long;
use Log::Log4perl;
use POSIX;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use MongoDB::GridFS;
use LWP::Parallel::UserAgent;
use HTTP::Request;
use lib $FindBin::Bin;
require "RateBeerCrawl.pm";

my $mongoUrl="dev.beerhunter.pl";
my $mongoPort=27017;
our $baseUrl=q(http://www.ratebeer.com);
our $crawlStartTime: shared;
our $badLinks :shared=0;
our $crawlCounter :shared =0;
our $respQ = Thread::Queue->new();
our $requestsPerBatch=10;

my $logconf = qq(
log4perl.category                   = WARN, Syncer, SyncerC

# File appender (unsynchronized)
log4perl.appender.Logfile           = Log::Log4perl::Appender::File
log4perl.appender.Logfile.autoflush = 1
log4perl.appender.Logfile.utf8      = 1
log4perl.appender.Logfile.filename  = rateBeerMaster.log
log4perl.appender.Logfile.mode      = truncate
log4perl.appender.Logfile.layout    = PatternLayout
log4perl.appender.Logfile.layout.ConversionPattern    = %5p (%F:%L) - %m%n

# Synchronizing appender, using the file appender above
log4perl.appender.Syncer            = Log::Log4perl::Appender::Synchronized
log4perl.appender.Syncer.appender   = Logfile

log4perl.appender.stdout=Log::Log4perl::Appender::Screen
log4j.appender.stdout.layout=SimpleLayout
log4j.appender.stdout.utf8=1
log4perl.appender.SyncerC            = Log::Log4perl::Appender::Synchronized
log4perl.appender.SyncerC.appender   = stdout

log4perl.logger.Beerhunter.RateBeerMaster=DEBUG
log4perl.logger.Beerhunter.BeerData=DEBUG
);

Log::Log4perl::init(\$logconf);
my $logger = Log::Log4perl->get_logger('Beerhunter.RateBeerMaster');

my $rescan; #if set, old beer data will be removed from the db
my $newscan; #if set, new crawling will be started, even if the previous one has not been completed
my $workers=2;
GetOptions('rescan' => \$rescan, 'newscan' => \$newscan, 'workers:i' => \$workers);
$logger->info("rescan is: $rescan, newscan is: $newscan, workers: $workers");

#connect do db
my $client = MongoDB::MongoClient->new(host => "$mongoUrl:$mongoPort");
my $beerDb=$client->get_database('beerDb');
my $crawls=$beerDb->get_collection('crawls');

#get last crawl ID if defined
my @lastCrawlID=$crawls->find->sort({id => -1})->limit(1)->all;
my $lastCrawlId;
$lastCrawlId = %{$lastCrawlID[0]}{"id"} if defined $lastCrawlID[0];

#check if this is the first scan
my $firstScan=0;
if(!defined $lastCrawlId){
  $logger->info("No lastCrawlID defined. Assuming this is first crawling.");
  $newscan=1;
  $firstScan=1;
  $lastCrawlId=-1;
}

#this can't be like this!!! I gotta be replacing beers one-by one. To avoid havaing empty db.
if($rescan){
  &clearBeerData;
}

########################################
# now I have crawlId. 
my $crawlId;
if($newscan){
  $crawlId=++$lastCrawlId;
  &closeLastCrawl() unless $firstScan;
  $crawls->insert({"id" => $crawlId});
}else{
  $crawlId=$lastCrawlId;
  $logger->info("No new crawl requested implicitly. Checking if old one is completed..");
  my %thisCrawl = %{($crawls->find({"id"=>$crawlId})->all)[0]};
  if($thisCrawl{completed}){
    $logger->info("Last crawl completed. Will perform a new one");
    $crawlId+=1;
    $crawls->insert({"id" => $crawlId});
  }else{
    $logger->info("Last crawl has not completed. I will cary on that one...");
  }
}

############################################################
# all set, get the shit rolling
$logger->info("Crawl id is $crawlId");
my $thisCrawl = ($crawls->find({"id"=>$crawlId})->all)[0];
$thisCrawl->{startTime}=&getTimestamp if ! defined $thisCrawl->{startTime};
$thisCrawl->{newscan}=$newscan if ! defined $thisCrawl->{newscan};
$thisCrawl->{rescan}=$rescan if ! defined $thisCrawl->{rescan};
$thisCrawl->{workers}=$workers if ! defined $thisCrawl->{workers};
$thisCrawl->{completed}=0 if ! defined $thisCrawl->{completed};
$thisCrawl->{rowsDone}=0 if ! defined $thisCrawl->{rowsDone};
if(! defined $thisCrawl->{beerFile}){
  my ($bFName, $lineCounter) = &getBeersFile();
  $logger->info("Got beer file. fname is $bFName. I will insert this file into db");
  $logger->info("Lines in the beerfile: $lineCounter");
  my $grid=$beerDb->get_gridfs;
  my $fh = IO::File->new($bFName, "r");
  my $bid = $grid->insert($fh);
  $logger->info("inserted file to db");
  $thisCrawl->{beerFile}=$bid;
  $thisCrawl->{rowsTotal}=$lineCounter;
  unlink $bFName;
}

#get the beerfile from the db. it's already good to go
my $grid=$beerDb->get_gridfs;
my $fh = $grid->get($thisCrawl->{beerFile});
$logger->info("Got beer file from the db");
my $outFName="beers_".$thisCrawl->{startTime}.".tmp";
open( my $outfile, ">",$outFName); 
$fh->print($outfile);
close $outfile;
#here the beerfile from the db is already saved from the db to local drive
$logger->info("file $outFName  written to disk from the db");
$crawls->update( {"id"=>$crawlId}, $thisCrawl);
$logger->info("Crawl metadata updated");
### metadata ready, record updated. Start crawling..
################################################

open(my $readBeers, "<", $outFName) or die;
$logger->info("opened $outFName for reading");
$logger->info("Starting dispatching loop");
my $pua = LWP::Parallel::UserAgent->new();
$pua->in_order  (0);  # handle requests in order of registration
$pua->duplicates(0);  # ignore duplicates
$pua->timeout   (22);  # in seconds
$pua->redirect  (1);  # follow redirects

my @requestsPool;
&initParsingEngine();
$crawlStartTime=time;
while(<$readBeers>){
  push @requestsPool, (HTTP::Request->new('GET', $_));
  my $arrSize = @requestsPool;

  if($arrSize >=  $requestsPerBatch || eof){
    $logger->info("gathered $requestsPerBatch requests. handling...");
    foreach my $req (@requestsPool){
      $logger->info("Registering ".$req->url);
      if ( my $res = $pua->register ($req) ) { 
        $logger-warn($res->error_as_HTML); 
      }  
    }
    my $entries = $pua->wait();
    @requestsPool=();
    $logger->info("handled $requestsPerBatch requests");

    #parse results
    foreach (keys %$entries){
      my $res = $entries->{$_}->response;
      my $url = $res->request->url;
      my $content = $res->content;
      my $code = $res->code;
      {
        lock $crawlCounter;
        $crawlCounter++;
      }
      if($code != 200){
        $logger->warn("unable to get the data from: $url");
        {
          lock $badLinks;
          $badLinks++;
        }
        next;
      }
      my $toQ={ "url"=>$url, "content"=>$content};
      $respQ->enqueue($toQ);
    }
  }

}
unlink $outFName; #file which contained crawled links
$logger->info("Removed $outFName from local drive.");

######################################################################
######################################################################
sub initParsingEngine{
  my $worker=threads->create(\&handleResponses);
  $logger->info("Detaching parsing thread...");
  $worker->detach;
  $logger->info("Detached  parsing thread...");
}

sub handleResponses{
  my $parser = Beerhunter::BeerData::RateBeerCrawl->new(); 
  while(1){
    my $toQ= $respQ->dequeue();
    my $urlRef = ($toQ->{url});
    my $url = $$urlRef;
    say ($url);
    my $content = $toQ->{content};
    my $beerHashRef=$parser->getDataFromRB($url, $content);
    my $localBadLinks;
    my $localCrawlCounter;
    my $elapsed;
    {
      lock $crawlStartTime;
      $elapsed = time - $crawlStartTime;
    }
    {
      lock $badLinks;
      $localBadLinks=$badLinks;
    }
    {
      lock $crawlCounter;
      $localCrawlCounter = $crawlCounter;
    }
    my $speed=$localCrawlCounter/$elapsed;
    $logger->info("Done $localCrawlCounter links in". substr($elapsed,0,7). " s. Speed: ".substr($speed,0,5). "(url/s). Bad links: ".$localBadLinks);
  }
}

sub prepareLink{
  s/\r?\n$//;
  my @row = split /\t/;
  my $rbId=decode_entities($row[0]); #rb id
  $rbId=~s/^\s+|\s+$//g;
  my $bName=decode_entities($row[1]); #beer name
  $bName=~s/^\s+|\s+$//g;
  my $ss=lc($bName); #search string
  $ss=~s/^\s+|\s+$//g;
  $ss=~s/ /-/g;
  my $brewery=decode_entities($row[3]); #brewery
  $brewery=~s/^\s+|\s+$//g;
  my $url=$baseUrl . '/beer/';
  $ss=~s/\.//g;
  $ss=~s/://g;
  $ss=~s/%//g;
  $ss=~s/\*//g;
  $ss=~s/<//g;
  $ss=~s/>//g;
  $url=$url.$ss."/".$rbId."/";
  $url =~ s/[^[:ascii:]]//g;
  $url =~ s/\(|\)|\&//g;
  return $url;
}

#temporary won't download new file!!!
## this sub downloads a zip, extraxts the beerlist and converts it to utf-8.
## removes all the garbage, leaving only the txt file in the dir
sub getBeersFile{
  my $beerListUrl=q(http://www.ratebeer.com/documents/downloads/beers.zip);
  my $beerZipFile="berrList.zip";
  my $extractedBeerList;
  my $counter=0;

  { 
    #download zip and extract
#  unlink  $beerZipFile;
    $logger->info("Downloading beer list.");
#  getstore($beerListUrl, $beerZipFile);
    $logger->info("Zipped beer list downloaded.");
    my $zippo = Archive::Zip->new;
    unless ( $zippo->read( $beerZipFile ) == AZ_OK ) {
      $logger->error("Can't open the zip file: $beerZipFile");
      die 'read error';
    }
    my @members = $zippo->memberNames;
    $extractedBeerList=$members[0];
    unlink $extractedBeerList;
    $logger->info("File with list is named: $extractedBeerList. Extracting from archive..");
    $zippo->extractMember($extractedBeerList);
#    unlink $beerZipFile;
    $logger->info("Beer list extracted");
  }

  {
    #convert and prepare ready links.....
    $logger->info("Converting beer list to utf-8 and preparing ready links..");
    open(my $fin,"< :raw :encoding(UTF-16LE) :crlf", $extractedBeerList) or die $!;
    my $tmpList="beersConverted.tmp";
    open (my $fout, "> :encoding(UTF-8)", $tmpList);
    $logger->info( "starting conversion loop");
    while(<$fin>){
      s/\r?\n$//; #windows-style chomp
      print $fout &prepareLink($_)."\n";
      $counter++;
    }
    close $fin;
    close $fout;
    move($tmpList, $extractedBeerList);
    $logger->info("converted and prepared");
  }
  return ($extractedBeerList, $counter);
}


sub getTimestamp{
  strftime("%Y-%m-%d_%H-%M-%S", localtime);
}

sub closeLastCrawl{
  $logger->info("newscan requested. Closing last crawl..");
  $logger->warn("not implemented!");
}

sub clearBeerData{
  $logger->info("rescan requested. Clearing old beer data..");
  $logger->warn("not implemented!");
}
