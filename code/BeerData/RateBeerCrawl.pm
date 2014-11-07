package Beerhunter::BeerData::RateBeerCrawl 0.01{
  use 5.018;
  use Data::Dumper;
  use LWP::Simple;
  use JSON;
  use Log::Log4perl;
  use HTML::Entities;
  use Encode;
  use URI::Escape;
  use HTML::TreeBuilder::XPath;
  use HTML::Tidy;

  Log::Log4perl::init_and_watch('../log4perl.conf',20);
  my $logger = Log::Log4perl->get_logger('Beerhunter.Crawlers.KikCrawler');
  our $baseUrl=q(http://www.ratebeer.com);
  our $badLinks=0;

  sub new{
    my ($class, @args) = @_;
    return bless {}, $class;
  }

  #handles one particular beer
  sub getDataFromRB{
    my $self = shift;
    my $url=shift;
    $logger->info("-------------------------------");
    $logger->info("Querying $url");
    my $beertml=get($url);
    if(defined $beertml){
      $logger->info("GET done");
      my $bData=$self->parseData($beertml);
      $logger->info("Crawled $url");
      return  $bData;
    }else{
      $logger->warn("Unable to GET the data for $url");
      open(my $badUrlFile, '>>', "badUrls.tmp") or die;
      select((select($badUrlFile),$|=1)[0]);
      print $badUrlFile "$url \n"; 
      close $badUrlFile;
      $badLinks++;
      return 1;
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

    my %beer;
    $beer{name}=$title;
    $beer{brewery}=$brewery;
    $beer{breweryLink}=$breweryLink;
    $beer{style}=$style;
    $beer{styleLink}=$styleLink;
    $beer{overallMark}=$overallMark;
    $beer{styleMark}=$styleMark;
    $beer{abv}=$abv;
    $beer{ratings}=$ratings;
    $beer{seasonal}=$seasonal;
    $beer{calories}=$calories;
    $beer{weightedAvg}=$weightedAvg;
    $beer{desc}=$desc;
    $beer{imgLink}=$imgLink;
    $beer{origin}=$origin;
    return \%beer;
  }

  #main entry routine
  #&test;
  #handleBeers;
  #my $crawler = Beerhunter::BeerData::RateBeerCrawl->new;
  #$crawler->test;
  #$crawler->handleBeers;
  1;
}
