package Beerhunter::Crawlers::CudaCrawler::Crawler 0.01{
  use 5.020;
  use Data::Dumper;
  use LWP::Simple;
  use HTML::TreeBuilder::XPath;
  use JSON;
  use Getopt::Long;
  use Log::Log4perl;
  use POSIX qw(strftime);
  use HTML::Entities;
  use Scalar::Util qw(looks_like_number);
  binmode STDOUT, ":utf8";

  sub new{
    my ($class, @args) = @_;
    return bless {}, $class;
  }

  sub crawl{
    #logger
    Log::Log4perl::init_and_watch('../../log4perl.conf',20);
    my $logger = Log::Log4perl->get_logger('Beerhunter.Crawlers.CudaCrawler');

    #options
    my $verbose;
    my $outBaseFname="cuda";
    my $barId="2";
    GetOptions("outBaseFname=s" => \$outBaseFname,
      "verbose"=>\$verbose,
      "barid"=>\$barId);

    #this one can change in the future...
    #my $url="https://fbrestaurants.menutabapp.com/menus?signed_request=HK8pKXJtQjoDFMFMP-WdE_8EV3FNAM0UbwEjBGKhLLQ.eyJhbGdvcml0aG0iOiJITUFDLVNIQTI1NiIsImlzc3VlZF9hdCI6MTQxNDM0NTY3MiwicGFnZSI6eyJpZCI6IjQyMTA3MTkwNzk4NDE5MSIsImFkbWluIjpmYWxzZSwibGlrZWQiOmZhbHNlfSwidXNlciI6eyJjb3VudHJ5IjoicGwiLCJsb2NhbGUiOiJlbl9VUyIsImFnZSI6eyJtaW4iOjIxfX19";

    my $url="http://api.menutabapp.com/restaurants/421071907984191/menus.htm";
    my $html = get($url);
    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse($html);

    my $contents=$tree->findnodes(q(//div[contains(concat(' ',@class,' '), ' container ')]//li//div[not(@*)]));
    my $nodes=$contents->size();
    $logger->info("Found $nodes nodes (beers :) ");

    my @beers;
    foreach my $node ($contents->get_nodelist){
      my %beer;
      my $bNameAndNo = $node->look_down("_tag", "h4")->as_trimmed_text;
      $bNameAndNo =~ /^(\d+)\./;
      $beer{tapNo}= $1 if defined $1;
      $bNameAndNo =~ s/^\d+\.\s*//;
      $beer{name} = $bNameAndNo;
      $beer{metadata} = $node->look_down("_tag", "p")->as_text;
      push @beers, \%beer;
      $logger->info("found beer: $bNameAndNo, on tap $beer{tapNo}, having metadata: $beer{metadata}");
    }

    my $datestring = strftime "-%F-%H-%M", localtime;
    my $outName = $barId."-".$outBaseFname.$datestring.".json";
    $outName="../out/$outName";

    my $jsonOut = encode_json \@beers;
    open(my $fh, '>', $outName) or die "Could not open file '$outName' $!";
    print $fh $jsonOut;
    close $fh;
    $logger->info("Cuda crawled. Output saved to $outName");
  }
}
