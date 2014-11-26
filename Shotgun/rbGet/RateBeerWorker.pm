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
use Mojo::UserAgent;
use Getopt::Long;
use Log::Log4perl;
use POSIX;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use HTTP::Request;
use lib $FindBin::Bin;
require "RateBeerCrawl.pm";
use YAML::Tiny;

######
### rbdata API requirements
### 1. store badUrls
#
#
#####

# non-configureable constants
our $baseUrl=q(http://www.ratebeer.com);

#public stuff
our $crawlStartTime;
our $respQ = Thread::Queue->new();
our $badLinks : shared = 0;
our $downloadCounterShared : shared =0;
our $parsersNo:shared =0;
our $lastRecordDownloadTime : shared = time;
our @downloadSpeedLastMany: shared = ();
our @downloadSpeedSamples;
our $crawlData; #hashref with crawl metadata
our $rowsTotalToDownloadForMe;
our $rowsDoneLast;

our $logconf = qq(
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
our $logger = Log::Log4perl->get_logger('Beerhunter.RateBeerMaster');

#########################################
## Options
our $batchsize=20; 
our $bigBatchRatio=3;
our $oldsource; #try to use  old beers.zip file if present
our $syncPeriod=120; #will make sure that all responses are parsed and persisted in DB every at most 120s
our $rbdataApiUrl="dev.beerhunter.pl";
our $rbdataApiPort="3000";
our $workersTotal=1;
our $myWorkerNo=1;
our $crawlTimestamp=ceil(time);
our $newRun=1; #if specified, starts it's work from the beggining. If not, tries to pick up last crawl 
GetOptions('batchsize:i' => \$batchsize, 'oldsource'=>\$oldsource, 'rbdataapiurl:s'=>\$rbdataApiUrl,
    'workerstotal:i'=>\$workersTotal, 'myworkerno:i'=>\$myWorkerNo, 'crawltimestamp:s'=>\$crawlTimestamp, 
    'newrun:i'=> \$newRun, 'bigbatchratio:i'=>\$bigBatchRatio);
$logger->info("batchsize: $batchsize, oldsource: $oldsource, rbdataapiurl: $rbdataApiUrl, workerstotal: $workersTotal,
    myworkerno: $myWorkerNo, crawltimestamp: $crawlTimestamp, newrun: $newRun, bigbatchratio: $bigBatchRatio");

my $worker = new();
$worker->start();

sub new{
    my ($class, @args) = @_;
    return bless {}, $class;
}

#####
#crawl metadata contains: finished, downloaded, workersTotal, timestamp, myWorkerNo, filename
#####

sub checkIfCrawlToPickUp{
    my $self = shift;
    if( -e "crawl.yml" ){
        my $yaml = YAML::Tiny->read('crawl.yml');
        $crawlData=$yaml->[0] if (defined $yaml && defined $yaml->[0]);
        if( defined $crawlData){
            if( ! $crawlData->{finished}){
                return $crawlData;
            }
        }
    }
    return 0;
}

sub updateCrawlMetadata{
    my $self = shift;
    unlink "crawl.yml" if( -e "crawl.yml");
    my $yaml = YAML::Tiny->new($crawlData);
    $yaml->write("crawl.yml");
}

sub startNewMetadata{
    my $self = shift;
    $crawlData->{crawlTimestamp} = $crawlTimestamp;
    $crawlData->{finished} = 0;
    $crawlData->{workersTotal}= $workersTotal;
    $crawlData->{myWorkerNo} = $myWorkerNo;
    $crawlData->{downloaded}=0;
    $crawlData->{filename}=undef;
    $crawlData->{lines}=undef;
    $crawlData->{badlinks}=0;
    $self->updateCrawlMetadata();
}

sub printCrawlMetadata{
    my $self = shift;
    $logger->info("-------------------- crawlData contents -----------------");
    $logger->info("crawlTimestamp: $crawlData->{crawlTimestamp}");
    $logger->info("finished: $crawlData->{finished}");
    $logger->info("workersTotal: $crawlData->{workersTotal}");
    $logger->info("myWorkerNo: $crawlData->{myWorkerNo}");
    $logger->info("downloaded: $crawlData->{downloaded}");
    $logger->info("filename: $crawlData->{filename}");
    $logger->info("lines: $crawlData->{lines}");
    $logger->info("badlinks: $crawlData->{badlinks}");
    $logger->info("---------------------------------------------------------");
}

sub start{
    my $self = shift;
    if($newRun){
        $logger->info("\"newCrawl\" flag specified. Starting new crawl.yml file");
        $self->startNewMetadata();
    }else{
        unless( $self->checkIfCrawlToPickUp()){
            $logger->info("no old crawl to pick up. Starting new one..");
            $self->startNewMetadata();
        }else{
            $logger->info("picked up old crawl");
        }
    }
    $self->printCrawlMetadata();

    $self->handleInputFile() unless $crawlData->{filename};
    $logger->info("Source filename is: $crawlData->{filename}. Lines in file: $crawlData->{lines}");
    my ($firstLineToDo, $lastLineToDo) = $self->countLinesRangeForMe();
    $logger->info("First line to do: $firstLineToDo, last line to do: $lastLineToDo"
        . " ,lines already done: $crawlData->{downloaded}");

    #so we already know the file, where to start and how much to do
    $self->crawlingLoop($firstLineToDo, $lastLineToDo);

}

sub countLinesRangeForMe{
    my $self= shift;
    my $linesPerWorker= ceil($crawlData->{lines} / $crawlData->{workersTotal});
    my $firstLineToDo=  ($crawlData->{myWorkerNo}-1) * $linesPerWorker +1;
    my $lastLineToDo = $firstLineToDo + $linesPerWorker -1;
    return ($firstLineToDo, $lastLineToDo);
}

sub handleInputFile{
    my $self = shift;
    my ($fname, $counter) = $self->getBeersFile();
    $crawlData->{filename} = $fname;
    $crawlData->{lines} = $counter;
    $self->updateCrawlMetadata();
}

sub crawlingLoop{
    my $self = shift;
    my ($firstLineToDo, $lastLineToDo)  = @_;
    my $totalLinesToDo = $lastLineToDo - $firstLineToDo +1;
    $rowsTotalToDownloadForMe=$totalLinesToDo;
    my $inputFile=$crawlData->{filename};
    open(my $readBeers, "<", $inputFile) or die;
    $logger->info("opened $inputFile for reading");
    $crawlStartTime=time;
    my $lastSyncTime=time;
    $rowsDoneLast = $crawlData->{downloaded};
    $logger->info("First line to do: $firstLineToDo, last line to do: $lastLineToDo, total lines to do: $totalLinesToDo");
    $logger->info("Already done rows: $rowsDoneLast.") if $rowsDoneLast>0;
    my $rowsToSkip = $rowsDoneLast+$firstLineToDo-1;
    $logger->info("Total rows to skip: $rowsToSkip");
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
    $logger->info("Starting the crawling loop..");
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
            $logger->info("Syncing \"downloaded\" value.");
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
            $crawlData->{downloaded}= $doneTotal;
            $self->updateCrawlMetadata();
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
    $crawlData->{finished}=1;
    $self->updateCrawlMetadata();
#unlink $inputFile; #file which contained crawled links
#$logger->info("Removed $inputFile from local drive.");
}

##so if there is more than 100 bad links in less then 10s -> it means probably network problem. So we stop
#    my $badLinkWindowLen=10;
#    my $badLinkWindowSpacing=10; #if there is no bad links within 10s - reset the algorith
#    my $badLinkWindowCount=100;
#    our $badLinkWindow : shared = 0;
#    our $badLinkWindowStart : shared = 0;
#    our $inBadLinkWindow: shared = 0;

#a single url has been downloaded
sub on_finish{
    $|=1;
    my $downCounterLocal;
    {
        lock $downloadCounterShared;
        $downCounterLocal = ++$downloadCounterShared;
        print ".";
    }
    my $results = shift;
    my $error = $results->has_error;
    my $success = $results->response->is_success;
    my $url =  $results->final_url;
    my $content = $results->response->decoded_content;
    my $wasBad=0;

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

            $crawlData->{badlinks}=$badLinks;
            &insertBadLink($url);
            $logger->warn("Bad link encountered: $url");
            $wasBad=1;
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
            my $timeSum;
            $timeSum += $_ for @downloadSpeedSamples;
            $localAvs = (scalar @downloadSpeedSamples)/$timeSum;
            $logger->debug("Download speed (last $batchsize links): ". substr($localAvs,0,4). " (url/s)");
            @downloadSpeedSamples=();
            push @downloadSpeedLastMany, $localAvs;
        }
    }
    my $bigbatch=$batchsize*$bigBatchRatio;
    if($downCounterLocal % $bigbatch ==0){
        {
            lock @downloadSpeedLastMany;
            my $sessionTime = time - $crawlStartTime;
            my $leftLinks= ($rowsTotalToDownloadForMe - ( $downCounterLocal+$rowsDoneLast));
            my $donePerc = (($downCounterLocal+$rowsDoneLast) / $rowsTotalToDownloadForMe) * 100;
            my $pendingJobs=$respQ->pending();
            my $etr=substr((($leftLinks*($sessionTime/$downCounterLocal))/3600),0,5);
            my $averageBigSpeed=sum(@downloadSpeedLastMany)/@downloadSpeedLastMany;

            $logger->info("Downloaded in this session: $downCounterLocal. Session time: ". substr(($sessionTime/3600),0,5).
                " h. Downloaded total: ". ($rowsDoneLast+$downCounterLocal) . ". Bad links: $badLinks. Left links: "
                . $leftLinks. "/". $rowsTotalToDownloadForMe . ". Pending parse jobs: $pendingJobs. done: "
                . substr($donePerc,0,5) ." %"
                ." Etr: $etr h");
            $logger->info("Download AVSs for last $bigbatch links (avg=". substr($averageBigSpeed,0,4) .") (url/s): "
                . join("   ", map( substr($_,0,4), @downloadSpeedLastMany) ));
            @downloadSpeedLastMany=();
        }
    }
    ############################################################
    unless($wasBad){
        my $toQ={ "url"=>$url, "content"=>$content};
        $respQ->enqueue($toQ);
    }
}

#######################################################################
#######################################################################
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
    $|=1;
    my $parser = Beerhunter::BeerData::RateBeerCrawl->new(); 

    my ($parsingThisSessionTotalTime, $parsedThisSessionLocal)=(0,0);
    $logger->info("Starting parser thread for parser#: ".$myNo);
    while(1){
        my $toQ= $respQ->dequeue();
        my $parseLoopTimer=time;
        my $urlRef = ($toQ->{url});
        my $url = $$urlRef;
        my $beerHashRef=$parser->parse_url($url, $toQ->{content});
        &insertToRbData($beerHashRef);
        $parsedThisSessionLocal++;
        $parseLoopTimer= time - $parseLoopTimer;

        $parsingThisSessionTotalTime+=$parseLoopTimer;
        my $bigbatchsize= $batchsize * $bigBatchRatio;
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

### this sub downloads a zip, extraxts the beerlist and converts it to utf-8.
### removes all the garbage, leaving only the txt file in the dir
### if $rescan is no, it will only select and save in a final file those beers, which are not yet present in our bdb 
## (bdb = beer DB :] )
sub getBeersFile{
    my $self = shift;
    my $beerListUrl=q(http://www.ratebeer.com/documents/downloads/beers.zip);
    my $beerZipFile="berrList.zip";
    my $extractedBeerList;
    my $counter=0;

    { 
        #download zip and extract if needed
        unless($oldsource && -e $beerZipFile){  #if really needed to download new zip
            unlink  $beerZipFile;
            $logger->info("Downloading beer list.");
            getstore($beerListUrl, $beerZipFile);
            $logger->info("Zipped beer list downloaded. Archive name: $beerZipFile");
        }

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
        $logger->info("Beer list extracted. Fname: $extractedBeerList");
    }

    my $finalName;
    {
        #convert and prepare ready links.....
        $logger->info("Converting beer list to utf-8 and preparing ready links..");
        open(my $fin,"< :raw :encoding(UTF-16LE) :crlf", $extractedBeerList) or die $!;
        my $tmpList="beersConverted.tmp";
        open (my $fout, "> :encoding(UTF-8)", $tmpList);
        $logger->info( "starting conversion loop");
        while(<$fin>){
            $counter++;
            $logger->info("lines done: $counter") if ($counter%20000 == 0);
            s/\r?\n$//; #windows-style chomp
            my $link=&prepareLink($_);
            print $fout $link."\n";
        }
        close $fin;
        close $fout;
        unlink $extractedBeerList;
        $finalName = $extractedBeerList. "_".$crawlData->{crawlTimestamp};
        move($tmpList, $finalName );
        $logger->info("converted and prepared");
    }
    return ($finalName, $counter);
}

########################################
# communication with rbData API
########################################
sub insertToRbData{
    my $toInsert=shift;
    $|=1;
    my $url = $rbdataApiUrl.":".$rbdataApiPort."/beer";
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->post( $url => form => $toInsert );
    unless (my $res = $tx->success){
        my $err = $tx->error;
        $logger->warn("$err->{code} response: $err->{message}") if $err->{code};
    }
}

sub insertBadLink{
    my $toInsert = shift;
    $|=1;
    my $url = $rbdataApiUrl.":".$rbdataApiPort."/badurl";
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->post( $url => form => {bad => $toInsert} );
    unless (my $res = $tx->success){
        my $err = $tx->error;
        $logger->warn("$err->{code} response: $err->{message}") if $err->{code};
    }
    $logger->info("badlink inserted to rbdata");
}

#sub getTimestamp{
#    strftime("%Y-%m-%d_%H-%M-%S", localtime);
#}
