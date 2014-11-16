package Beerhunter::Crawlers::KikCrawler::Crawler 0.01{
    use 5.020;
    use Data::Dumper;
    use LWP::Simple;
    use JSON;
    use Getopt::Long;
    use Log::Log4perl;
    use POSIX qw(strftime);
    use HTML::Entities;
    use Scalar::Util qw(looks_like_number);
    
    sub new{
	my ($class, @args) = @_;
	return bless {}, $class;
    }
   
    sub crawl{ 
	#logger
	Log::Log4perl::init_and_watch('../../log4perl.conf',20);
	my $logger = Log::Log4perl->get_logger('Beerhunter.Crawlers.KikCrawler');
	
	#options
	my $verbose;
	my $outBaseFname="kik";
	my $barId="1";
	GetOptions("outBaseFname=s" => \$outBaseFname,
		   "verbose"=>\$verbose,
		   "barid"=>\$barId);
	
	
	my $url='http://www.kufleikapsle.pl/wp-content/themes/kufleikapsle/js/beer-data.js';
	my $content = get($url);    
	die "Can't GET beer data from $url" if (! defined $content);
	
	return 0 unless($content=~/var\s+taps\s+=\s+(\[.+?\])/gi);
	my @decoded_beers = @{decode_json($1)};
	$logger->debug( Dumper(\@decoded_beers));
	
	my $datestring = strftime "-%F-%H-%M", localtime;
	my $outName = $barId."-".$outBaseFname.$datestring.".json";
	$outName="../out/$outName";
	
	my @beers;
	foreach(@decoded_beers){
	    my %beer;
	    $beer{name}= decode_entities($_->{name});
	    $beer{abv}=decode_entities($_->{abv});
	    $beer{blg}=decode_entities($_->{blg});
	    $beer{ibu}=decode_entities($_->{ibu}) if (looks_like_number($_->{ibu}));
	    $beer{style}=decode_entities($_->{style_name});
	    $beer{brewery}=decode_entities($_->{brewery_name});
	    $beer{price}=$_->{price};
	    $beer{price}->{currency}="PLN";
	    
	    push @beers, \%beer;
	}
	 
	my $jsonOut = encode_json \@beers;
	open(my $fh, '>', $outName) or die "Could not open file '$outName' $!";
	print $fh $jsonOut;
	close $fh;
	$logger->info("kik crawled. Output saved to $outName");
	return 1;
    }
    1;
}	
