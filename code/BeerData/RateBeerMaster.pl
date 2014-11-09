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
log4perl.logger.Beerhunter.RateBeerCrawl=WARN
);

Log::Log4perl::init(\$logconf);
my $logger = Log::Log4perl->get_logger('Beerhunter.RateBeerMaster');

#by default, if no options specified, continues an old scan and looks up only new beers (added to RB since the last scan)
#if last scan has been completed, starts a new one.
my $rescan; #if set, it will query for all the beers. If not, it will query only for newly added beers(default)
my $newscan; #if set, new crawling will be started, even if the previous one has not been completed
my $batchsize=10; #currently ignored
GetOptions('rescan' => \$rescan, 'newscan' => \$newscan, 'batchsize:i' => \$batchsize);
$logger->info("rescan is: $rescan, newscan is: $newscan, batchsize: $batchsize");

#connect do db
my $client = MongoDB::MongoClient->new(host => "$mongoUrl:$mongoPort");
my $beerDb=$client->get_database('beerDb');
my $crawls=$beerDb->get_collection('crawls');

#get last crawl ID if defined
my @lastCrawlID=$crawls->find->sort({id => -1})->limit(1)->all;
my $lastCrawlId;
$lastCrawlId = %{$lastCrawlID[0]}{"id"} if defined $lastCrawlID[0];

#check if this is the first scan.
my $firstScan=0;
if(!defined $lastCrawlId){
    $logger->info("No lastCrawlID defined. Assuming this is first crawling.");
    $newscan=1;
    $rescan=1;
    $firstScan=1;
    $lastCrawlId=-1;
}

########################################
# now I have crawlId. 
my $crawlId;
if($newscan){
    &closeCrawl($lastCrawlId) unless $firstScan;
    $crawlId=++$lastCrawlId;
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
$newscan=$thisCrawl->{newscan} if defined $thisCrawl->{newscan};
$thisCrawl->{newscan}=$newscan if ! defined $thisCrawl->{newscan};
$rescan=$thisCrawl->{rescan} if defined $thisCrawl->{rescan};
$thisCrawl->{rescan}=$rescan if ! defined $thisCrawl->{rescan};
$batchsize=$thisCrawl->{batchsize} if defined $thisCrawl->{batchsize};
$thisCrawl->{batchsize}=$batchsize if ! defined $thisCrawl->{batchsize};
$thisCrawl->{completed}=0 if ! defined $thisCrawl->{completed};
$thisCrawl->{rowsDone}=0 if ! defined $thisCrawl->{rowsDone};
if(! defined $thisCrawl->{beerFile}){
    my ($bFName, $lineCounter, $toDownloadCounter) = &getBeersFile($rescan);
    $logger->info("Got beer file. fname is $bFName. I will insert this file into db");
    $logger->info("Lines total in the beerfile: $lineCounter Lines to download: $toDownloadCounter. Will save only 
        lines to download.");
    my $grid=$beerDb->get_gridfs;
    my $fh = IO::File->new($bFName, "r");
    my $bid = $grid->insert($fh);
    $logger->info("inserted file to db");
    $thisCrawl->{beerFile}=$bid;
    $thisCrawl->{rowsTotal}=$lineCounter;
    $thisCrawl->{rowsToDownload}=$toDownloadCounter;
    unlink $bFName;
}
my $rowsTotalInFile=$thisCrawl->{rowsTotal};
my $rowsTotalToDownload=$thisCrawl->{rowsToDownload};

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
### metadata ready, record updated, file ready. Start crawling!!
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
my $rowsDoneLast = $thisCrawl->{rowsDone};
$logger->info("already done rows: $rowsDoneLast. I will skip them.") if $rowsDoneLast>0;
my $rowsToSkip=$rowsDoneLast if $rowsDoneLast>0;
while(<$readBeers>){
    if($rowsToSkip>0){
        --$rowsToSkip;
        next;
    }
    push @requestsPool, (HTTP::Request->new('GET', $_));
    my $arrSize = @requestsPool;

    if($arrSize >=  $batchsize || eof){
        foreach my $req (@requestsPool){
            $logger->trace("Registering ".$req->url." in GETter");
            if ( my $res = $pua->register ($req) ) { 
                $logger-warn($res->error_as_HTML); 
            }  
        }
        my $entries = $pua->wait();
        @requestsPool=();
        $logger->info("GOT $batchsize requests. Queueing them for parsing threads");

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
        $pua->initialize();
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
    my $rbBeers=$beerDb->get_collection('rbBeers');
    my $rowsToDoTotal = $rowsTotalToDownload - $rowsDoneLast; #how much left in general
    my $rowsToDoFromOrgFile = $rowsTotalToDownload; #how big was the task initially
    my $alreadyDone=0; #done in this session
    my $totalAlreadyDone=$rowsDoneLast; #done total
    my $parsingTotalTime=0;
    my @doneHashes;
    while(1){
        my $toQ= $respQ->dequeue();
        my $parseLoopTimer=time;
        my $urlRef = ($toQ->{url});
        my $url = $$urlRef;
        my $beerHashRef=$parser->getDataFromRB($url, $toQ->{content});
        push @doneHashes, $beerHashRef;
        $alreadyDone++;
        $totalAlreadyDone++;

        if($alreadyDone%10 ==0){
            foreach my $bHash(@doneHashes){
                my $url = $bHash->{url};
                $rbBeers->remove({"url"=>$url});
                $rbBeers->insert($bHash);
            }
            @doneHashes=();

            $thisCrawl->{rowsDone}=$totalAlreadyDone;
            $crawls->update( {"id"=>$crawlId}, $thisCrawl);

            #do some reporting....
            my $pending= $respQ->pending();
            my ($localBadLinks, $elapsed );
            {
                lock $crawlStartTime;
                $elapsed = (time - $crawlStartTime);
            }
            {
                lock $badLinks;
                $localBadLinks=$badLinks;
            }
            my $speed=$alreadyDone/$elapsed;
            $elapsed/=3600;
            my $rowsTotalToDoLeft = $rowsToDoTotal-$alreadyDone;
            my $etr=($rowsTotalToDoLeft/$speed)/3600;
            $parseLoopTimer=time - $parseLoopTimer;
            $parsingTotalTime+=$parseLoopTimer;
            my $parserUtil= substr(($parsingTotalTime/($elapsed*3600))*100,0,5);
            $logger->info("Crawled in this session: $alreadyDone. Crawled total: $totalAlreadyDone. " 
                ."Time of this session: ". substr($elapsed,0,4). " h. "
                ."Download speed: ".substr($speed,0,5). "(url/s). Bad links: ".$localBadLinks
                . ". Left links to do: $rowsTotalToDoLeft/$rowsToDoFromOrgFile. Parsing queue size: $pending. ETR: ".substr($etr,0,4). " h"
                .". Parser thread utilization is: $parserUtil %");
        }
    }
    $thisCrawl->{completed}=1;
    $thisCrawl->{finishTime}=time;
    $crawls->update( {"id"=>$crawlId}, $thisCrawl);
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
## if $rescan is no, it will only select and save in a final file those beers, which are not yet present in our bdb 
# (bdb = beer DB :] )
sub getBeersFile{
    my $rescan=shift;
    my $beerListUrl=q(http://www.ratebeer.com/documents/downloads/beers.zip);
    my $beerZipFile="berrList.zip";
    my $extractedBeerList;
    my $counter=0;
    my $toDownloadCounter=0;

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
        my $rbBeers=$beerDb->get_collection('rbBeers');
        while(<$fin>){
            $counter++;
            s/\r?\n$//; #windows-style chomp
            my $link=&prepareLink($_);

            #check if we already have it..
            if(!$rescan){
                my $b = $rbBeers->find({"url"=> $link});
                next if ($b->count()==1);
            }
            $toDownloadCounter++;
            print $fout $link."\n";
        }
        close $fin;
        close $fout;
        move($tmpList, $extractedBeerList);
        $logger->info("converted and prepared");
    }
    return ($extractedBeerList, $counter, $toDownloadCounter);
}


sub getTimestamp{
    strftime("%Y-%m-%d_%H-%M-%S", localtime);
}

sub closeCrawl{
    my $crawlId=shift;
    $logger->info("Closing crawl # $crawlId..");
    $crawls->update( {"id"=>$crawlId},{"completed"=>1});
    $logger->info("Closed crawl # $crawlId");
}
