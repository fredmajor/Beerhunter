use 5.018;
use common::sense;
use utf8;
use threads;
use threads::shared;
use List::Util qw(sum);
use Thread::Queue;
use File::Copy;
use FindBin;
use Time::HiRes qw/time/;
use HTML::Entities;
use IO::File;
use Data::Dumper;
use YADA;
use LWP::Simple;
use MongoDB;
use MongoDB::OID;
use Getopt::Long;
use Log::Log4perl;
use POSIX;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use MongoDB::GridFS;
#use LWP::Parallel::UserAgent;
use HTTP::Request;
use lib $FindBin::Bin;
require "RateBeerCrawl.pm";

our $mongoUrl="dev.beerhunter.pl";
our $mongoPort=27017;
our $baseUrl=q(http://www.ratebeer.com);
our $syncPeriod=120; #will make sure that all responses are parsed and persisted in DB every at most 120s

#more public stuff
our $crawlStartTime;
our $respQ = Thread::Queue->new();
our $badLinks : shared = 0;
our $downloadCounterShared : shared =0;
our $parsersNo:shared =0;
our $lastRecordDownloadTime : shared = time;
our @downloadSpeedLastMany: shared = ();
my @downloadSpeedSamples;

my $logconf = qq(
log4perl.category                   = WARN, Logfile, stdout
# log4perl.category                   = WARN, Syncer, SyncerC

# File appender (unsynchronized)
log4perl.appender.Logfile           = Log::Log4perl::Appender::File
log4perl.appender.Logfile.autoflush = 1
log4perl.appender.Logfile.utf8      = 1
log4perl.appender.Logfile.filename  = rateBeerMaster.log
log4perl.appender.Logfile.mode      = truncate
log4perl.appender.Logfile.layout    = PatternLayout
log4perl.appender.Logfile.layout.ConversionPattern    = %5p (%F:%L) - %m%n

# Synchronizing appender, using the file appender above
# log4perl.appender.Syncer            = Log::Log4perl::Appender::Synchronized
# log4perl.appender.Syncer.appender   = Logfile

log4perl.appender.stdout=Log::Log4perl::Appender::Screen
log4j.appender.stdout.layout=SimpleLayout
log4j.appender.stdout.utf8=1
# log4perl.appender.SyncerC            = Log::Log4perl::Appender::Synchronized
# log4perl.appender.SyncerC.appender   = stdout

log4perl.logger.Beerhunter.RateBeerMaster=DEBUG
log4perl.logger.Beerhunter.RateBeerCrawl=INFO
);

Log::Log4perl::init(\$logconf);
my $logger = Log::Log4perl->get_logger('Beerhunter.RateBeerMaster');

#by default, if no options specified, continues an old scan and looks up only new beers (added to RB since the last scan)
#if last scan has been completed, starts a new one.
my $rescan; #if set, it will query for all the beers. If not, it will query only for newly added beers(default)
my $newscan; #if set, new crawling will be started, even if the previous one has not been completed
my $batchsize=20; #currently ignored
my $oldsource; #try to use  old beers.zip file if present
GetOptions('rescan' => \$rescan, 'newscan' => \$newscan, 'batchsize:i' => \$batchsize, 'oldsource'=>\$oldsource);
$logger->info("rescan is: $rescan, newscan is: $newscan, batchsize: $batchsize, oldsource: $oldsource");

#connect do db
my $client = MongoDB::MongoClient->new(host => "$mongoUrl:$mongoPort");
my $beerDb=$client->get_database('beerDb');
my $crawls=$beerDb->get_collection('crawls');
my $crawlSpeed=$beerDb->get_collection('crawlSpeed');

#get last crawl ID if defined. Otherwise return "-1".
my @lastCrawlID=$crawls->find->sort({id => -1})->limit(1)->all;
my $lastCrawlId=-1;
$lastCrawlId = %{$lastCrawlID[0]}{"id"} if defined $lastCrawlID[0];

#check if this is the first scan.
if($lastCrawlId==-1){
    $logger->info("No lastCrawlID defined. Assuming this is first crawling. Setting newscan and rescan.");
    $newscan=1;
    $rescan=1;
}
$logger->info("lastCrawlId = $lastCrawlId");

########################################
# now let's establish this crawlId and update db if needed
my $crawlId;
my $lastCrawlRef = ($crawls->find({"id"=>$lastCrawlId})->all)[0];
my %lastCrawl;
my %lastCrawl = %{$lastCrawlRef} if defined $lastCrawlRef;
if($newscan || (defined %lastCrawl && $lastCrawl{completed}) ){
    $logger->info("newscan requested. This means I will start a new crawling from scratches.") if $newscan;
    $logger->info("last crawl compleated. This one will start from the beggining") 
        if (!$newscan && defined %lastCrawl &&  $lastCrawl{completed});
    &closeCrawl($lastCrawlId) if $lastCrawlId!=-1;
    $crawlId=++$lastCrawlId;
    $crawls->insert({"id" => $crawlId});
}else{
    $logger->info("Last crawl has not completed. I will cary on that one...");
    $crawlId= $lastCrawlId;
}
my $thisSpeed=($crawlSpeed->find({"crawlId"=>$crawlId})->all)[0];
$crawlSpeed->insert({"crawlId"=>$crawlId}) if !defined $thisSpeed;

############################################################
# set some crawl metadata if needed
$logger->info("Crawl id is $crawlId");
my $thisCrawl = ($crawls->find({"id"=>$crawlId})->all)[0];
$thisCrawl->{startTime}=&getTimestamp if ! defined $thisCrawl->{startTime};
$thisCrawl->{newscan}=$newscan if ! defined $thisCrawl->{newscan};
$rescan=$thisCrawl->{rescan} if defined $thisCrawl->{rescan};
$thisCrawl->{rescan}=$rescan if ! defined $thisCrawl->{rescan};
$thisCrawl->{completed}=0 if ! defined $thisCrawl->{completed};
$thisCrawl->{rowsDone}=0 if ! defined $thisCrawl->{rowsDone};
my $oldBatchsize=$thisCrawl->{batchsize} if defined $thisCrawl->{batchsize};
$thisCrawl->{batchsize}=$batchsize if ! defined $thisCrawl->{batchsize};
$thisCrawl->{batchsize}=$batchsize if (defined $oldBatchsize && $oldBatchsize!=$batchsize);
$crawls->update( {"id"=>$crawlId}, $thisCrawl);


#############################################################
#handle the file if not set (firstcrawl? )
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
    $thisCrawl->{rowsTotalInFile}=$lineCounter;
    $thisCrawl->{rowsToDownload}=$toDownloadCounter;
    $crawls->update( {"id"=>$crawlId}, $thisCrawl);
    unlink $bFName;
    $logger->info("Crawl metadata updated");
}

######################################################################
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
################################################

################################################################################
## stuff for cawling itself
open(my $readBeers, "<", $outFName) or die;
$logger->info("opened $outFName for reading");
$crawlStartTime=time;
my $lastSyncTime=time;
my $rowsDoneLast = $thisCrawl->{rowsDone};
$logger->info("already done rows: $rowsDoneLast. I will skip them.") if $rowsDoneLast>0;
my $rowsToSkip=$rowsDoneLast if $rowsDoneLast>0;
$logger->info("Entering crawling loop");
my $rowsTotalToDownload=$thisCrawl->{rowsToDownload};
&initParsingEngine();

my $q=YADA->new(
    common_opts => {
        # Available opts @ http://curl.haxx.se/libcurl/c/curl_easy_setopt.html
        encoding        => '',
        followlocation  => 1,
        maxredirs       => 5,
    }, 
    http_response => 1, 
    max => 10,
    retry =>3
);

my @requestsPool;
while(<$readBeers>){
    if($rowsToSkip>0){
        --$rowsToSkip;
        next;
    }

    push @requestsPool, $_;
    my $poolSize = @requestsPool;

    if($poolSize >= $batchsize ||eof){
        $q->append(\@requestsPool, \&on_finish)->wait();
        @requestsPool=();
    }

    #update DB. this is to handle interupts properly
    if(time - $lastSyncTime > $syncPeriod){
        $logger->info("Syncing rowsDone value in DB");
        while($respQ->pending() != 0 ){
            $logger->info("There are still pending tasks in the parser queue. Waiting.. Pending taks: "
                .$respQ->pending);
            sleep 1;
        }
        my $doneTotal;
        {
            lock $downloadCounterShared;
            $doneTotal = $rowsDoneLast+$downloadCounterShared;
        }
        $thisCrawl->{rowsDone}=$doneTotal;
        $crawls->update( {"id"=>$crawlId}, $thisCrawl);
        $logger->info("Synced. Rows done total: $doneTotal");
        $lastSyncTime = time;
    }

    #add more parsing threads if needed
    {
        lock $parsersNo;
        if($respQ->pending > 10 && $parsersNo<2){
            $logger->warn("More than 40 parsing tasks in the Q. Adding 1 more parsing thread. Total parsers will be: "
                .($parsersNo+1));
            &initParsingEngine();
        }
    }
}
$thisCrawl->{completed}=1;
$thisCrawl->{finishTime}=time;
$crawls->update( {"id"=>$crawlId}, $thisCrawl);
#unlink $outFName; #file which contained crawled links
#$logger->info("Removed $outFName from local drive.");

#so if there is more than 100 bad links in less then 10s -> it means probably network problem. So we stop
my $badLinkWindowLen=10;
my $badLinkWindowSpacing=10; #if there is no bad links within 10s - reset the algorith
my $badLinkWindowCount=100;
our $badLinkWindow : shared = 0;
our $badLinkWindowStart : shared = 0;
our $inBadLinkWindow: shared = 0;

#a single url has been downloaded
sub on_finish{
    $|=1;
    my $downCounterLocal;
    {
        lock $downloadCounterShared;
        $downCounterLocal = ++$downloadCounterShared;
    }
    my $results = shift;
    my $error = $results->has_error;
    my $success = $results->response->is_success;
    my $url =  $results->final_url;
    my $content = $results->response->decoded_content;

    #handle bad links
    if(!$success || $error){
        {
            lock $badLinks;
            $badLinks++;

            ############################################################
            #### bad link sliding window algorith
            #if(time - $badLinkWindowStart > $badLinkWindowLen){ # we're already past the window. Start a new one
            #    $inBadLinkWindow = 0;
            #}

            #if($inBadLinkWindow){
            #    if(time - $badLinkWindowStart > $badLinkWindowLen){ # we're already past the window. Start a new one
            #        $badLinkWindow = 1;
            #        $badLinkWindowStart = time;
            #        $inBadLinkWindow=1;
            #        $logger->warn("starting new badLinkWindow..");
            #    }else{ #still in old window
            #        $badLinkWindow++;
            #        if($badLinkWindow > $badLinkWindowCount){
            #            $logger->warn("more than $badLinkWindowCount in $badLinkWindowLen s! Stopping...");
            #        }
            #    }
            #}
            ############################################################

            if (! defined $thisCrawl->{badlinks}){
                $thisCrawl->{badlinks}=[];
            }
            push @{$thisCrawl->{badlinks}}, $url;
            $crawls->update({"id"=>$crawlId}, $thisCrawl);
            $logger->warn("Bad link encountered: $url");
        }
    }

    ############################################################
    #print and save some download speed stats
    my $localAvs;
    {
        lock $lastRecordDownloadTime;
        my $elapsed =  time - $lastRecordDownloadTime;
        $lastRecordDownloadTime = time;
        push @downloadSpeedSamples, $elapsed;
        if(scalar @downloadSpeedSamples == $batchsize){
            my $updTimer=time;
            for my $elap (@downloadSpeedSamples){
                $elap+=0;
                $crawlSpeed->update({"crawlId"=>$crawlId}, {'$push'=>{'speed' => $elap}});
            }
            $updTimer = time - $updTimer;
            my $timeSum;
            $timeSum += $_ for @downloadSpeedSamples;
            $localAvs = (scalar @downloadSpeedSamples)/$timeSum;
            $logger->debug("(update time:". substr($updTimer,0,4).") Download speed (last $batchsize links): ". substr($localAvs,0,4). " (url/s)");
            #$logger->info("Download speed(last $batchsize links): ". substr($localAvs,0,4). " (url/s)");
            @downloadSpeedSamples=();
            push @downloadSpeedLastMany, $localAvs;
        }
    }
    my $bigbatch=$batchsize*10;
    if($downCounterLocal % $bigbatch ==0){
        {
            lock @downloadSpeedLastMany;
            my $sessionTime = time - $crawlStartTime;
            my $leftLinks= ($rowsTotalToDownload - ( $downCounterLocal+$rowsDoneLast));
            my $pendingJobs=$respQ->pending();
            my $etr=substr((($leftLinks*($sessionTime/$downCounterLocal))/3600),0,5);
            my $averageBigSpeed=sum(@downloadSpeedLastMany)/@downloadSpeedLastMany;

            $logger->info("Downloaded in this session: $downCounterLocal. Session time: ". substr(($sessionTime/3600),0,5).
                " h. Downloaded total: ". ($rowsDoneLast+$downCounterLocal) . ". Bad links: $badLinks. Left links: "
                . $leftLinks. "/". $rowsTotalToDownload . ". Pending parse jobs: $pendingJobs. Etr: $etr h");
            $logger->info("Download AVSs for last $bigbatch links (avg=". substr($averageBigSpeed,0,4) .") (url/s): "
                . join("\t", map( substr($_,0,4), @downloadSpeedLastMany) ));
            @downloadSpeedLastMany=();
        }
    }
    ############################################################
    my $toQ={ "url"=>$url, "content"=>$content};
    $respQ->enqueue($toQ);
}

######################################################################
######################################################################
sub initParsingEngine{
    {
        lock $parsersNo;
        my $worker=threads->create(\&handleResponses, ++$parsersNo);
        $worker->detach;
        $logger->info("New parser started. Parsers total: ". $parsersNo);
    }
}

sub handleResponses{
    my $myNo = shift;
    my $parser = Beerhunter::BeerData::RateBeerCrawl->new(); 
    my $client = MongoDB::MongoClient->new(host => "$mongoUrl:$mongoPort");
    my $beerDb=$client->get_database('beerDb');
    my $rbBeers=$beerDb->get_collection('rbBeers');

    my ($parsingThisSessionTotalTime, $parsedThisSessionLocal)=(0,0);
    $logger->info("Starting parser thread for parser#: ".$myNo);
    while(1){
        my $toQ= $respQ->dequeue();
        my $parseLoopTimer=time;
        my $urlRef = ($toQ->{url});
        my $url = $$urlRef;
        my $beerHashRef=$parser->parse_url($url, $toQ->{content});
        $rbBeers->remove({"url"=>$url});
        $rbBeers->insert($beerHashRef);
        $parsedThisSessionLocal++;
        $parseLoopTimer= time - $parseLoopTimer;

        $parsingThisSessionTotalTime+=$parseLoopTimer;
        my $bigbatchsize= $batchsize *10;
        if($parsedThisSessionLocal % $bigbatchsize == 0 ){
            my $parseSpeed=$parsedThisSessionLocal/$parsingThisSessionTotalTime;
            $parseSpeed=substr($parseSpeed,0,5);
            $logger->info("AVG parsing speed (last $bigbatchsize links, parser#: $myNo): $parseSpeed (pages/s)");
            ($parsingThisSessionTotalTime, $parsedThisSessionLocal)=(0,0);
        }
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
        unlink  $beerZipFile;
        $logger->info("Downloading beer list.");
        getstore($beerListUrl, $beerZipFile) unless $oldsource;
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
        unlink $beerZipFile;
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
            $logger->info("lines done: $counter") if ($counter%1000 == 0);
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
