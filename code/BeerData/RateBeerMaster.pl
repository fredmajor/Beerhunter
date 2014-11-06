use 5.018;
use Time::HiRes qw/time/;
use HTML::Entities;
no warnings 'utf8';
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

my $mongoUrl="dev.beerhunter.pl";
my $mongoPort=27017;

Log::Log4perl::init_and_watch('../log4perl.conf',20);
my $logger = Log::Log4perl->get_logger('Beerhunter.Crawlers.KikCrawler');

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

#remove all beer data already crawled from RB and stored
if($rescan){
  &clearBeerData;
}


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
  my $bFName = &getBeersFile();
  $logger->info("Got beer file. fname is $bFName");
  my $grid=$beerDb->get_gridfs;
  #open(my $fh,"< :encoding(UTF-16)", $bFName) or die $!;
  my $fh = IO::File->new($bFName, "r");
  my $bid = $grid->insert($fh);
  $logger->info("inserted file to db");
  $thisCrawl->{beerFile}=$bid;
#  unlink $bFName;
}

#handle the beerfile
my $grid=$beerDb->get_gridfs;
my $fh = $grid->get($thisCrawl->{beerFile});
$logger->info("Got beer file from the db");
my $outFName="beers_".$thisCrawl->{startTime}.".tmp";
open( my $outfile, ">",$outFName); 
$fh->print($outfile);
close $outfile;
$logger->info("file $outFName  written to disk from the db");
if( ! defined $thisCrawl->{rowsTotal} ){
  $logger->info("No file length specified in the db. Counting..");
  my $lines=0;
  open(my $readBeers, "<", $outFName);
  $lines++ while(<$readBeers>);
  close $readBeers;
  $logger->info("lines in $outFName#: $lines");
  $thisCrawl->{rowsTotal}=$lines;
}
$crawls->update( {"id"=>$crawlId}, $thisCrawl);
########
### metadata ready, record updated. Start crawling..

my $baseUrl=q(http://www.ratebeer.com);
open(my $readBeers, "<", $outFName);
my $c=0;
my $startTime=time;
my $badLinks=0;
while(<$readBeers>){
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
  say "id: $rbId beer: $bName search string: $ss brewery: $brewery";
  $c++;
  #file line already parsed, let's go to RB :]
#  $self->getDataFromRB($ss,$rbId,$c);
  my $elasped=time - $startTime;
  my $speed=$c/$elasped;
  $logger->info("Done $c links in $elasped s. Speed: ".substr($speed,0,5). "(url/s). Bad links: ".$badLinks);
}



unlink $outFName;
$logger->info("Removed $outFName from local drive.");

######################################################################
######################################################################
#temporary won't download new file!!!
sub getBeersFile{
  my $beerListUrl=q(http://www.ratebeer.com/documents/downloads/beers.zip);
  my $beerFile="berrList.zip";
#  unlink  $beerFile;

  $logger->info("Downloading beer list.");
#  getstore($beerListUrl, $beerFile);
  $logger->info("Beer list downloaded.");

  my $zippo = Archive::Zip->new;

  unless ( $zippo->read( $beerFile ) == AZ_OK ) {
    $logger->error("Can't open the zip file: $beerFile");
    die 'read error';
  }
  $logger->info("Beer list unzipped");
  my @members = $zippo->memberNames;
  my $listFName=$members[0];
  unlink $listFName;
  $logger->info("File with list is named: $listFName. Extracting from archive..");
  $zippo->extractMember($listFName);
  $logger->info("Beer list extracted");
#  unlink $beerFile;
  return $listFName;
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
