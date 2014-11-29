use 5.018;
use common::sense;
use utf8;
use Data::Dumper;
use Getopt::Long;
use Mojolicious::Lite;
use MongoDB;

my $mongoHost="dev.beerhunter.pl";
my $mongoPort="27017";
my $apiRoot="";
my $apiPort=3000;

GetOptions('mongohost:s'=> \$mongoHost, 'mongoport:i'=>\$mongoPort, 
    'apiroot:s'=> \$apiRoot, 'apiport:i' => \$apiPort);

my $myUrl="http://" . $apiRoot . "*:" . $apiPort;
app->config(hypnotoad => {listen => [$myUrl]});

say "mongo host is: $mongoHost, mongo port is: $mongoPort";

get '/' => sub{
    my $c = shift;
    $c->render(text => 'ALL GLORY TO THE HYPNOTOAD!!');
};

post '/badurl' => sub{
    my $c = shift;
    my $url = $c->param('bad');
    my $mongo = MongoDB::MongoClient->new(host => $mongoHost. ":" . $mongoPort);
    my $rbdata = $mongo->get_database('rbdata');
    $rbdata->get_collection('badurl')->insert({bad => $url});
    $c->render(text => 'ok');
};

post '/beer' => sub{
    my $c = shift;
    my $beer = $c->req->params->to_hash;
    $beer->{rbid}+=0;
    $beer->{abv}+=0 if defined $beer->{abv};
    $beer->{overallMark}+=0 if defined $beer->{overallMark};
    $beer->{styleMark}+=0 if defined $beer->{styleMark};
    $beer->{ratings}+=0 if defined $beer->{ratings};
    $beer->{ibu}+=0 if defined $beer->{ibu};
    $beer->{calories}+=0 if defined $beer->{calories};
    $beer->{weightedAvg}+=0 if defined $beer->{weightedAvg};
    $beer->{weightedAvg}+=0 if defined $beer->{weightedAvg};
    my $mongo = MongoDB::MongoClient->new(host => $mongoHost. ":" . $mongoPort);
    my $rbdata = $mongo->get_database('rbdata');
    $rbdata->get_collection('beer')->remove( {"rbid" => $beer->{rbid}} );
    $rbdata->get_collection('beer')->insert($beer);
    $c->render(text => 'ok');
};

app->start;
