package Beerhunter::BeerData::RateBeerCrawl 0.01{
    use 5.018;
    use utf8;
    use Data::Dumper;
    use LWP::Simple;
    use JSON;
    use Log::Log4perl qw(:easy);
    use HTML::Entities;
    use Encode;
    use URI::Escape;
    use HTML::TreeBuilder::XPath;
    use HTML::Tidy;

    our $logger;
    our $baseUrl=q(http://www.ratebeer.com);

    sub new{
        my ($class, @args) = @_;
        $logger = Log::Log4perl->get_logger('Beerhunter.RateBeerCrawl');
        return bless {}, $class;
    }

    #handles one particular beer
    sub getDataFromRB{
        my $self = shift;
        my $url=shift;
        my $text = shift;
        $logger->debug("Parsing $url");
        my $bData=$self->parseData($text);
        $bData->{"url"}=$url;
        $logger->info("Parsed $url");
        return  $bData;
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

        $logger->trace( "Beer name: $title");
        $logger->trace( "Brewery: $brewery");
        $logger->trace( "Brewery link is: $breweryLink");
        $logger->trace("Style: $style") if defined $style;
        $logger->trace("Style: $styleLink") if defined $styleLink;
        $logger->trace("Overall mark: $overallMark") if defined $overallMark;
        $logger->trace("Style mark: $styleMark") if defined $styleMark;
        $logger->trace("Abv: $abv") if defined $abv;
        $logger->trace("Ratings: $ratings") if defined $ratings;
        $logger->trace("Seasonal: $seasonal") if defined $seasonal;
        $logger->trace("Calories: $calories") if defined $calories;
        $logger->trace("Weighted avg:  $weightedAvg") if defined $weightedAvg;
        $logger->trace("Description:  $desc") if defined $desc;
        $logger->trace("Img link:  $imgLink") if defined $imgLink;
        $logger->trace("Origin is:  $origin") if defined $origin;

        $tree->delete();

        my %beer;
        $beer{name}=$title if defined $title;
        $beer{brewery}=$brewery if defined $brewery;
        $beer{breweryLink}=$baseUrl.$breweryLink if defined $breweryLink;
        $beer{style}=$style if defined $style;
        $beer{styleLink}=$baseUrl.$styleLink if defined $styleLink;
        $beer{overallMark}=$overallMark if defined $overallMark;
        $beer{styleMark}=$styleMark if defined $styleMark;
        $beer{abv}=$abv if defined $abv;
        $beer{ratings}=$ratings if defined $ratings;
        $beer{seasonal}=$seasonal if defined $seasonal;
        $beer{calories}=$calories if defined $calories;
        $beer{weightedAvg}=$weightedAvg if defined $weightedAvg;
        $beer{desc}=$desc if defined $desc;
        $beer{imgLink}=$imgLink if defined $imgLink;
        $beer{origin}=$origin if defined $origin;
        return \%beer;
        #TODO - dorobic IBU!!!!
    }

    1;
}
