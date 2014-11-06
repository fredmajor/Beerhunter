package Beerhunter::BeerData::RateBeerCrawl 0.01{
  use 5.018;
  use Data::Dumper;
  use LWP::Simple;
  use JSON;
  use Getopt::Long;
  use Log::Log4perl;
  use POSIX qw(strftime);
  use WWW::Mechanize;
  use HTML::Entities;
  use Encode;
  use URI::Escape;
  use HTML::TreeBuilder::XPath;
  use HTML::Tidy;
  no warnings 'utf8';

  Log::Log4perl::init_and_watch('../log4perl.conf',20);
  my $logger = Log::Log4perl->get_logger('Beerhunter.Crawlers.KikCrawler');
  our $baseUrl=q(http://www.ratebeer.com);
  our $badLinks=0;

  sub new{
    my ($class, @args) = @_;
    return bless {}, $class;
  }

  #reads from a file and gets the data
  sub handleBeers{
    my $self = shift;
    open(my $fh,"< :encoding(UTF-16)", "beers.txt") or die $!;
    my @beerData;
    my $c=0;
    my $startTime=time;
    while (<$fh>) {
      s/\r?\n$//;
      my @row = split /\t/;
      my $rbId=decode_entities($row[0]); #rb id
      $rbId=~s/^\s+|\s+$//g;
      my $bName=decode_entities($row[1]); #beer name
      $bName=~s/^\s+|\s+$//g;
      #my $ss=Encode::decode('utf8', uri_unescape($row[2]));
      my $ss=lc($bName); #search string
      $ss=~s/^\s+|\s+$//g;
      $ss=~s/ /-/g;
      my $brewery=decode_entities($row[3]); #brewery
      $brewery=~s/^\s+|\s+$//g;
      #say "id: $rbId beer: $bName ss: $ss brewery: $brewery";
      $c++;
      #file line already parsed, let's go to RB :]
      $self->getDataFromRB($ss,$rbId,$c);
      my $elasped=time - $startTime;
      my $speed=$c/$elasped;
      $logger->info("Done $c links in $elasped s. Speed: ".substr($speed,0,5). "(url/s). Bad links: ".$badLinks);
    }
    $logger->info("Processing done");
    close $fh;
    return 1;
  }

  #handles one particular beer
  sub getDataFromRB{
    my $self = shift;
    my ($strPath, $id,$c) = @_;
    my $url=$baseUrl . '/beer/';
    $strPath=~s/\.//g;
    $strPath=~s/://g;
    $strPath=~s/%//g;
    $strPath=~s/\*//g;
    $strPath=~s/<//g;
    $strPath=~s/>//g;
    $url=$url.$strPath."/".$id."/";
    $url =~ s/[^[:ascii:]]//g;
    $url =~ s/\(|\)|\&//g;
    $logger->info("-------------------------------");
    $logger->info("$c: Querying $url");
    my $beertml=get($url);
    if(defined $beertml){
      $logger->info("GET done");
      $self->parseData($beertml);
      $logger->info("Crawled $c");
    }else{
      $logger->warn("Unable to GET the data for $url");
      open(my $badUrlFile, '>>', "badUrls") or die;
      select((select($badUrlFile),$|=1)[0]);
      print $badUrlFile "$url \n"; 
      close $badUrlFile;
      $badLinks++;
    }
  }

  sub test{
    my $self = shift;
    my @files = qw/ grut.html doubleTrouble.html/;
    #my @files = qw/ doubleTrouble.html/;
    foreach my $fname(@files){
      say"------------------";
      say "file is $fname";
      my $wholeFile;
      {
        local $/=undef;
        open(my $fh, $fname) or die $!;
        $wholeFile=<$fh>;
        close $fh;
      }
      $self->parseData($wholeFile);
    }
  }

  sub parseData{
    my $self=shift;
    my $beertml = shift;
    unless(defined $beertml){
      $logger->warn("passed html is not defined!");
      return 1;
    }
    #clean it up a bit
    my $tidy=HTML::Tidy->new();
    my $tidyBeers = $tidy->clean($beertml);
    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse($tidyBeers);

    #get the data from cleaned html
    my $title = $tree->findvalue(q(.//*[@id='container']/table//tr[1]/td[2]/div/div[4]/h1));
    my $breweryNode=$tree->findnodes
    (q(.//*[@id='container']/table//tr[2]/td[2]/div/table[1]//tr/td[2]/div[1]/big/b/a));
    my $brewery=$breweryNode->[0]->as_text() if defined $breweryNode->[0];
    my $breweryLink = $breweryNode->[0]->attr('href') if defined $breweryNode->[0];

    #style
    my $bStylePath=q(.//*[@id='container']/table//tr[2]/td[2]/div/table[1]//tr/td[2]/div[1]/a[1]);
    my ($style, $styleLink);
    if($tree->exists($bStylePath)){
      my $styleNodes=$tree->findnodes($bStylePath);
      $style=$styleNodes->[0]->as_text;
      $styleLink=$styleNodes->[0]->attr('href');
    }

    #overall & style marks 
    my $overallPath=q(.//*[@id='container']/table//tr[2]/td[2]/div/table[1]//tr/td[1]/div[1]/div/span/span[2]);
    my $overallMark;
    if ($tree->exists($overallPath)) {
      $overallMark=$tree->findvalue($overallPath);
    }

    my $stylePath=q(.//*[@id='container']/table//tr[2]/td[2]/div/table[1]//tr/td[1]/div[2]/div/span[1]);
    my $styleMark;
    if ($tree->exists($stylePath)) {
      $styleMark=$tree->findvalue($stylePath);
    }

    my $infoPath=q(.//*[@id='container']/table//tr[2]/td[2]/div/div[1]);
    my ($abv, $ratings, $seasonal, $calories, $weightedAvg);
    if ($tree->exists($infoPath)) {
      my $wholeDiv=$tree->findvalue($infoPath);
      {
        $wholeDiv=~/([0-9]*\.?[0-9]+)\s*%/i;
        $abv=$1 if defined $1;
      }

      {
        $wholeDiv=~/ratings:\s*(\d+)/i;
        $ratings=$1 if defined $1;
      }

      {
        $wholeDiv=~/seasonal:\s*(\w+)/i;
        $seasonal=$1 if defined $1;
      }

      {
        $wholeDiv=~/calories:\s*(\d+)/i;
        $calories=$1 if defined $1;
      }

      {
        $wholeDiv=~/avg:\s*([0-9]*\.?[0-9]+)/i;
        $weightedAvg=$1 if defined $1;
      }

    }

    my $descPath=q(.//*[@id='container']/table//tr[2]/td[2]/div/div[3]/div/text());
    my $desc;
    if($tree->exists($descPath)){
      $desc=$tree->findvalue($descPath);
      $desc=~s/^Description:\s*//;
    }

    #beer image
    my $imgPath=q(.//*[@id='beerImg']);
    my $imgLink;
    if($tree->exists($imgPath)){
      my $imgNodes=$tree->findnodes($imgPath);
      $imgLink=$imgNodes->[0]->attr('src') if defined $imgNodes->[0];
    }

    #origin
    my $originPath=q(.//*[@id='container']/table//tr[2]/td[2]/div/table[1]//tr/td[2]/div[1]);
    my $originPathText=q(.//*[@id='container']/table//tr[2]/td[2]/div/table[1]//tr/td[2]/div[1]/text());
    my $origin;
    if($tree->exists($originPath)){
      my $originNode=$tree->findnodes($originPath)->[0];
      my @linkTags=$originNode->look_down('_tag','a');
      my $linksSize = @linkTags;
      if($linksSize >= 2){
        my $allDivText=$tree->findnodes_as_string($originPath);
        if($allDivText=~/brewed at/i){
          shift @linkTags;
        }
        shift @linkTags; shift @linkTags;
        $origin  = join( ',', (map{$_->as_text} @linkTags));
      }
      my $allTexts=$tree->findvalue($originPathText);
      $allTexts=~s/style\s*://gi;
      $allTexts=~s/^\s+|\s+$//g;
      $origin=~s/^\s+|\s+$//g;
      $origin= $origin . $allTexts;
      $origin=~s/\s+//g;
      $origin=~s/,/, /g;
      $origin=~s/^\s*,//;
    }

    $logger->info( "Beer name: $title");
    $logger->info( "Brewery: $brewery");
    $logger->info( "Brewery link is: $breweryLink");
    $logger->info("Style: $style") if defined $style;
    $logger->info("Style: $styleLink") if defined $styleLink;
    $logger->info("Overall mark: $overallMark") if defined $overallMark;
    $logger->info("Style mark: $styleMark") if defined $styleMark;
    $logger->info("Abv: $abv") if defined $abv;
    $logger->info("Ratings: $ratings") if defined $ratings;
    $logger->info("Seasonal: $seasonal") if defined $seasonal;
    $logger->info("Calories: $calories") if defined $calories;
    $logger->info("Weighted avg:  $weightedAvg") if defined $weightedAvg;
    $logger->info("Description:  $desc") if defined $desc;
    $logger->info("Img link:  $imgLink") if defined $imgLink;
    $logger->info("Origin is:  $origin") if defined $origin;


    $tree->delete();
  }

  #main entry routine

  #&test;
  #handleBeers;
  my $crawler = Beerhunter::BeerData::RateBeerCrawl->new;
  #$crawler->test;
  $crawler->handleBeers;

}
