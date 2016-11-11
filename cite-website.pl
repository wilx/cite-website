#! env perl

#no warnings qw(experimental::signatures);

package RefRec;

use v5.20;
use strict;
use warnings;
use criticism;

use Moose;
use MooseX::StrictConstructor;

has 'id' => (is => 'rw', isa => 'Maybe[Str]');
has 'title' => (is => 'rw', isa => 'Maybe[Str]');
has 'type' => (is => 'rw', isa => 'Maybe[Str]');
has 'author' => (is => 'rw', isa => 'Maybe[ArrayRef[HashRef[Str]]]',
    default => sub { return []; });
has 'abstract' => (is => 'rw', isa => 'Maybe[Str]');
has 'keyword' => (is => 'rw', isa => 'Maybe[Str]');
sub container_title;
has 'container-title' => (is => 'rw', isa => 'Maybe[Str]',
    reader => &container_title, writer => &container_title);
has 'publisher' => (is => 'rw', isa => 'Maybe[Str]');
sub publisher_place;
has 'publisher-place' => (is => 'rw', isa => 'Maybe[Str]',
    reader => &publisher_place, writer => &publisher_place);
has 'volume' => (is => 'rw', isa => 'Maybe[Str]');
has 'issue' => (is => 'rw', isa => 'Maybe[Str]');
has 'page' => (is => 'rw', isa => 'Maybe[Str]');
has 'issued' => (is => 'rw', isa => 'Maybe[HashRef|ArrayRef]',
                 default => undef );
has 'accessed' => (is => 'rw', isa => 'Maybe[HashRef|ArrayRef]',
                   default => undef );
has 'ISBN' => (is => 'rw', isa => 'Maybe[Str]');
has 'ISSN' => (is => 'rw', isa => 'Maybe[Str]');
has 'URL' => (is => 'rw', isa => 'Maybe[Str]');
has 'DOI' => (is => 'rw', isa => 'Maybe[Str]');

sub publisher_place {
    my $self = shift;
    if (scalar(@_) == 1) {
        $self->{"publisher-place"} = shift;
    }
    return $self->{"name"};
}

sub container_title {
    my $self = shift;
    if (scalar(@_) == 1) {
        $self->{"content-title"} = shift;
    }
    return $self->{"name"};
}

no Moose;


package main;

use v5.20;
use strict;
use warnings;
use criticism;
## no critic (ProhibitSubroutinePrototypes)
use experimental 'switch';
use feature qw(signatures);
no warnings qw(experimental::signatures);

use Data::Dumper;
use LWP::Simple qw();
use Data::OpenGraph;
use HTML::Microdata;
use HTML::DublinCore;
use HTML::TreeBuilder::XPath;
use HTML::Entities;
use HTML::HeadParser;
use URI;
use RDF::Query;
use YAML qw();
use JSON qw();
use DateTime::Format::ISO8601;
use DateTime::Format::W3CDTF;
use DateTime::Format::HTTP;
use DateTime::Format::CLDR;
use DateTime::Format::Epoch;
use IO::Handle;
use Scalar::Util qw(reftype);
use String::Util qw(trim);
use Data::DPath 'dpath';
use TryCatch;

use Carp;
local $SIG{__WARN__} = sub { print( Carp::longmess (shift) ); };
#local $SIG{__DIE__} = sub { print( Carp::longmess (shift) ); };

STDOUT->binmode(":utf8");
STDERR->binmode(":utf8");

my $ua = LWP::UserAgent->new(keep_alive => 10);
push @{ $ua->requests_redirectable }, 'POST';
$ua->cookie_jar({});
$ua->timeout(30);
# Fake user agent identification is necessary. Some webs simply do not
# respond if they think this is some kind of crawler they do not like.
$ua->agent('Mozilla/5.0 (Windows NT 6.1; WOW64; rv:40.0) Gecko/20100101 Firefox/40.1');
my $response = $ua->get($ARGV[0]);
my $htmldoc;
if ($response->is_success) {
    $htmldoc = $response->decoded_content;
}
else {
    #print STDERR "resp: ", Dumper($response), "\n";
    die $response->status_line;
}

# HTML headers parsing.

my $html_headers = HTTP::Headers->new;
my $headers_parser = HTML::HeadParser->new($html_headers);
$headers_parser->parse($htmldoc);

# Open Graph parsing.

my $og = Data::OpenGraph->parse_string($htmldoc);
#print STDERR "og:\n", Dumper($og->{properties}), "\n";
if (test($og)) {
    print STDERR "It looks like we have some Open Graph data.\n";
}

# Microdata parsing.

my $microdata = HTML::Microdata->extract($htmldoc, base => $ARGV[0]);
my $items = $microdata->items;
#print STDERR "microdata as JSON:\n", Dumper($items), "\n";
if (test($items)) {
    print STDERR "It looks like we have some microdata in HTML.\n";
}

# HTML as tree parsing.

my $tree = HTML::TreeBuilder::XPath->new;
$tree->parse($htmldoc);

# Microdata from parsely-page meta tag JSON content.

my $parsely_page = $html_headers->header('X-Meta-Parsely-Page');
my $parsely_page_content;
if (test($parsely_page)) {
    $parsely_page_content = JSON::decode_json($parsely_page);
    print STDERR "It looks like we have found some Parsely-Page microdata.\n";
    #print STDERR "parsely-page content:\n", Dumper($parsely_page_content), "\n";
}

# Schema.org data out of <script type="application/ld+json"> tag.

my $schema_org_ld_json;

try {
    my $ld_json = $tree->findvalue('//script[@type="application/ld+json"]/text()');
    #print STDERR "raw schema.org JSON+LD data:\n", Dumper($ld_json), "\n";
    if (test($ld_json)) {
        try {
            $schema_org_ld_json = JSON::decode_json($ld_json);
            print STDERR "schema.org JSON+LD data:\n", Dumper($schema_org_ld_json), "\n";
            if (!(test($schema_org_ld_json->{'@context'})
                  && $schema_org_ld_json->{'@context'} eq 'http://schema.org'
                  && test($schema_org_ld_json->{'@type'}))) {
                $schema_org_ld_json = undef;
            }
            else {
                print STDERR "It looks like we have some schema.org data in JSON+LD.\n";
            }
        }
        catch {};
    }
}
catch {};

# Parse language out of meta headers.

my $lang;
{
    my $keywords_lang = $tree->findvalue('//head/meta[@name="keywords"]/@lang');
    #print STDERR "keywords_lang: ", Dumper($keywords_lang), "\n";

    my $description_lang = $tree->findvalue('//head/meta[@name="description"]/@lang');
    #print STDERR "description_lang: ", Dumper($description_lang), "\n";

    my $og_locale = $og->property('locale');
    #print STDERR "og:locale: ", $og_locale // "(undef)", "\n";

    $lang = $og_locale // $keywords_lang // $description_lang;
    #print STDERR "lang: ", $lang // "(undef)", "\n";
}

# Parse DublinCore meta headers.

my $dc = HTML::DublinCore->new($htmldoc);
#print STDERR "DublinCore:\n", Dumper($dc), "\n";

# Fill in %entry.

sub test {
    my $x = $_[0];
    return defined ($x)
        && ((ref $x ne ''
             && ((reftype($x) eq 'ARRAY'
                  && scalar @$x)
                 || (reftype($x) eq 'HASH'
                     && scalar keys %$x)))
            || (ref($x) eq ''
                && length($x) != 0));
}

sub choose {
    my @values = @_;
    print STDERR "choose(", Dumper(\@values), ")\n";
    foreach my $val (@values) {
        if (test($val)) {
            print STDERR "Choosing ", Dumper($val), "\n";
            return $val;
        }
    }

    return;
}

sub read_og_array {
    my ($og, $prop) = @_;
    my $prop_value = $og->property($prop);
    my @arr;
    if (test($prop_value)) {
        if (ref $prop_value ne ''
            && reftype($prop_value) eq 'ARRAY') {
            @arr = @{$prop_value};
        }
        else {
            @arr = ();
            @arr[0] = $prop_value;
        }
    }
    return @arr;
}


sub date_conversion {
    my $date = $_[0];
    my $year = $date->year;
    my $month = $date->month;
    my $day = $date->day;

    my $issued;
    if ($year && $month && $day) {
        $issued = {'date-parts' => [[$year, $month, $day]]};
    }
    elsif ($year) {
        $issued = [{'year' => $year}];
    }
    else {
        print STDERR "Unrecognizable date.\n";
    }
}


sub parse_author {
    my ($text, $additional_name) = @_;
    my $author = {};

    if ($text =~ /^\s*([^,]+)\s*,\s*(.*\S)\s*$/) {
        my $family = $1;
        my $given = $2;
        $author->{'family'} = $family;
        $author->{'given'} = $given;
    }
    elsif ($text =~ /^\s*((?:\S+\s+|\S+)+)\s+(\S+)\s*$/) {
        my $family = $2;
        my $given = $1;
        $author->{'family'} = $family;
        $author->{'given'} = $given;
    }
    else {
        $author->{'family'} = $text;
    }

    if (test($additional_name)) {
        $author->{'given'} .= " (" . $additional_name . ")";
    }

    return $author;
}


sub date_parse {
    my $str = $_[0];

    # Some web sites (www.washingtonpost.com) fail at to provide a date that
    # can be parsed by any of of the code below by using only 3 digit time
    # zone offset: 2016-01-27T02:24-500. Fix it here.

    #print STDERR "original date: ", $str, "\n";
    $str =~ s/^(\d\d\d\d-?\d\d-?\d\dT\d\d:?\d\d[+-])(\d\d\d)$/${1}0$2/;
    #print STDERR "fixed date: ", $str, "\n";

    # Try various parsing routines.

    try {
        my $date = DateTime::Format::ISO8601->parse_datetime($str);
        return $date;
    }
    catch {};

    try {
        my $date = DateTime::Format::HTTP->parse_datetime($str);
        return $date;
    }
    catch {};

    if (test($lang)) {
        try {
            my $locale = DateTime::Locale->load($lang);
            my $cldr = DateTime::Format::CLDR->new(
                pattern => $locale->date_format_long,
                locale => $locale);

            #print STDERR "CLDR pattern: ", $cldr->pattern, "\n";
            my $date = $cldr->parse_datetime($str);
            die "could not parse date $str: " . $cldr->errmsg() unless defined $date;
        }
        catch {};
    }

    # Parse POSIX seconds since epoch time stamp.
    if ($str =~ /\d{10,}/) {
        try {
            my $dt = DateTime->new( year => 1970, month => 1, day => 1 );
            my $parser = DateTime::Format::Epoch->new(
                epoch => $dt,
                unit => 'seconds',
                type => 'bigint',
                skip_leap_seconds => 1,
                start_at => 0,
                local_epoch => undef);
            my $date = $parser->parse_datetime($str);
            #print STDERR "date from epoch: ", $date, "\n";
            return $date;
        }
        catch {};
    }

    die "the date " . $str . " could not be parsed";
}

# Build RefRec out of OpenGraph data.

sub processOpenGraph ($og) {
    my $ogRec = RefRec->new;

    my $title = $og->property('title');
    if (test($title)) {
        $ogRec->title(decode_entities($title));
    }

    my $description = $og->property('description');
    if (test($description)) {
        $ogRec->abstract(trim(decode_entities($description)));
    }

    my $url = $og->property('url');
    if (test($url)) {
        $ogRec->URL($url);
    }

    my $publisher = $og->property('site_name');
    if (test($publisher)) {
        $ogRec->publisher(decode_entities($publisher));
    }

    my $og_type = $og->property('_basictype');
    if (test($og_type)) {
        print STDERR "It looks like we have Open Graph type ", $og_type, ".\n";
        my $type;
        given ($og_type) {
            when ("article") { $type = "article"; }
            when ("book") { $type = "book"; }
            when ("website") { $type = "webpage"; }
            default { $type = "webpage"; }
        }
        $ogRec->type($type);
    }
    else {
        print STDERR "og:type attribute is missing.\n";
        $ogRec->type("webpage");
    }


    if (test($og_type)) {
        my $og_issued_date_str;
        given ($og_type) {
            when ("article") {
                $og_issued_date_str = $og->property("$og_type:published_time");
            }
            when ("book") {
                $og_issued_date_str = $og->property("$og_type:release_date");
            }
        }

        #print STDERR "published time: ", $og_issued_date_str // "(undef)", "\n";
        if (test($og_issued_date_str)) {
            try {
                my $date = date_parse($og_issued_date_str);
                my $year = $date->year;

                $ogRec->issued(date_conversion($date));

                # TODO: Add 'id' generation for final reference record.
                #if (exists $entry{'id'} && $year) {
                #    $entry{'id'} .= $year;
                #}
            }
            catch {};
        }
    }
    elsif (! test($ogRec->issued)) {
        # Try article:published_time anyway. Some web sites are retarded like
        # that. We need to get it through DOM instead of Data::OpenGraph because
        # the Data::OpenGraph::Parser does not see it if og:type is not defined.

        my $published_time_str = $tree->findvalue(
            '//head/meta[@property="article:published_time"]/@content');
        if (test($published_time_str)) {
            try {
                my $date = date_parse($published_time_str);
                #print STDERR "date: ", Dumper($date), "\n";
                $ogRec->issued(date_conversion($date));

                $ogRec->type('article');
                print STDERR "setting og_type to article because article:published_time is present\n";
            }
            catch {};
        }
    }

    #my $id = undef;

    if (test($og_type)) {
        if ($og_type eq 'book'
            && test($og->property("$og_type:isbn"))) {
            $ogRec->ISBN($og->property("$og_type:isbn"));
        }

        if (! test($publisher)
            && test($og->property("$og_type:publisher"))) {
            $publisher = $og->property("$og_type:publisher");
            $ogRec->publisher($publisher);
        }

        my @og_tags = read_og_array ($og, "$og_type:tag");
        #print STDERR "tags: ", Dumper($og->property("$og_type:tag")), "\n";
        #print STDERR "tags: ", Dumper(\@og_tags), "\n";
        if (scalar @og_tags) {
            $ogRec->keyword(join ", ", @og_tags);
        }
    }

    # Author.

    if (test($og_type)) {
        my @creators = read_og_array ($og, "$og_type:author");
        #print STDERR "creators: ", Dumper(\@creators), "\n";
        if (scalar @creators) {
            foreach my $creator (@creators) {
                #print STDERR "creator: >$creator<\n";
                my $creator_text = $creator;
                my $author = parse_author($creator_text);
                push @{$ogRec->author}, $author;
            }
        }
    }

    return $ogRec;
}

my $ogRec = RefRec->new;
if (test($og)) {
    $ogRec = processOpenGraph($og);
}


# Microdata using the schema.org entities.

sub processSchemaOrg($items) {
    my $mdRec = RefRec->new;

    my @md_authors = dpath('//author/*')->match($items);
    #print STDERR "microdata authors:\n", Dumper(@md_authors), "\n";

    if (test(\@md_authors)) {
        print STDERR ("It looks like we have ", scalar @md_authors,
                      " schema.org authors.\n");
        foreach my $md_author (@md_authors) {
            if (ref $md_author ne ''
                && exists $md_author->{'type'}
                && $md_author->{'type'} eq 'http://schema.org/Person') {
                my @authors = dpath('/properties/name/*[0]')->match($md_author);
                if (test(@authors)) {
                    #print STDERR "author: ", Dumper(@authors), "\n";
                    my @additionalName = dpath('/properties/additionalName/*[0]')
                        ->match($md_author);

                    my $author = parse_author($authors[0], $additionalName[0]);
                    # if (! test($id)) {
                    #     $id = $author->{'family'};
                    #     $id =~ s/\W//g;
                    #     $id = lc $id;
                    # }
                    push @{$mdRec->author}, $author;
                }
            }
            else {
                print STDERR "Found author but not type http://schema.org/Person: ",
                $md_author, "\n";
            }
        }
    }



    my @md_articles = dpath(
        '//*/[key eq "type"'
        . ' && (value eq "http://schema.org/Article"'
        . '     || value eq "http://schema.org/CreativeWork"'
        . '     || value eq "http://schema.org/NewsArticle"'
        . '     || value eq "http://schema.org/VideoObject"'
        . '     || value eq "http://schema.org/ScholarlyArticle"'
        . '     || value eq "http://schema.org/BlogPosting")]/..')
        ->match($items);
    if (test(@md_articles)) {
        print STDERR "It looks like we have an instance of schema.org article.\n";
    }

    #print STDERR "article entry:\n", Dumper(@md_articles), "\n";
    if (test(\@md_articles)
        && test($md_articles[0]{'properties'}{'datePublished'}[0])) {
        try {
            my $date = date_parse(
                $md_articles[0]{'properties'}{'datePublished'}[0]);
            $mdRec->issued(date_conversion($date));
        }
        catch {};
    }

    if (test(\@md_articles)
        && test($md_articles[0]{'properties'}{'description'}[0])) {
        $mdRec->abstract($md_articles[0]{'properties'}{'description'}[0]);
    }

    if (test(\@md_articles)
        && test($md_articles[0]{'properties'}{'keywords'})) {
        $mdRec->keyword(join ", ", @{$md_articles[0]{'properties'}{'keywords'}});
    }

    my @ispartof = dpath(
        '/properties/isPartOf/*/'
        . '[key eq "type"'
        . ' && value eq "http://schema.org/PublicationVolume"]/'
        . '../properties')
        ->match($md_articles[0]);
    #print STDERR "ispartof:\n", Dumper(\@ispartof), "\n";
    if (test(@ispartof)) {
        print STDERR "It looks like we have isPartOf/PublicationVolume in article.\n";


        my @vol = dpath('/volumeNumber/*[0]')->match($ispartof[0]);
        #print STDERR "volume:\n", Dumper(\@vol), "\n";
        if (test(\@vol)) {
            $mdRec->volume($vol[0]);
        }



        my @cont = dpath('/isPartOf/*[0]/*/'
                         . '[key eq "type"'
                         . ' && value eq "http://schema.org/Periodical"]/'
                         . '../properties/name/*[0]')->match($ispartof[0]);
        if (test (\@cont)) {
            $mdRec->container_title($cont[0]);
        }

    }

    return $mdRec;
}

my $mdRec = RefRec->new;
if (test($items)) {
    $mdRec = processSchemaOrg($items);
}


# Microdata from parsely-page meta tag JSON content.

sub processParselyPage ($parsely_page_content) {
    my $parselyPageRec = RefRec->new;

    if (test($parsely_page_content->{'authors'})) {
        if ((ref $parsely_page_content->{'authors'} // '') eq 'ARRAY') {
            foreach my $author_str (@{$parsely_page_content->{'authors'}}) {
                my $author = parse_author($author_str);
                push @{$parselyPageRec->author}, $author;
            }
        }
        else {
            my $author = parse_author($parsely_page_content->{'authors'});
            push @{$parselyPageRec->author}, $author;
        }
    }

    if (test($parsely_page_content->{'title'})) {
        $parselyPageRec->title($parsely_page_content->{'title'});
    }

    if (test($parsely_page_content->{'pub_date'})) {
        try {
            my $date = date_parse($parsely_page_content->{'pub_date'});
            $parselyPageRec->issued(date_conversion($date));
        }
        catch {};
    }

    if ((ref $parsely_page_content->{'tags'} // '') eq 'ARRAY') {
        foreach my $tag_str (@{$parsely_page_content->{'tags'}}) {
            push @{$parselyPageRec->keyword}, $tag_str;
        }
    }
    else {
        my $tag_str = parse_author($parsely_page_content->{'tags'});
        push @{$parselyPageRec->keyword}, $tag_str;
    }

    return $parselyPageRec;
}

my $parselyPageRec = RefRec->new;
if (test($parsely_page_content)) {
    $parselyPageRec = processParselyPage($parsely_page_content);
}


# Schema.org microdata in JSON+LD in <script type="application/ld+json">.

sub processSchemaOrgJsonLd ($schema_org_ld_json) {
    my $schemaOrgJsonLd = RefRec->new;

    my $context;
    if (! ((test($context = $schema_org_ld_json->{'@context'}))
           && $context eq 'http://schema.org')) {
        # Return early.
        return $schemaOrgJsonLd;
    }

    if (test($schema_org_ld_json->{'datePublish'})) {
        try {
            my $date = date_parse($schema_org_ld_json->{'datePublished'});
            $schemaOrgJsonLd->issued(date_conversion($date));
        }
        catch {};
    }
    elsif (test($schema_org_ld_json->{'dateCreated'})) {
        try {
            my $date = date_parse($schema_org_ld_json->{'dateCreated'});
            $schemaOrgJsonLd->issued(date_conversion($date));
        }
        catch {};
    }



    return $schemaOrgJsonLd;
}

my $schemaOrgJsonLd = processSchemaOrgJsonLd($schema_org_ld_json);


# arXiv.org metadata.

sub processArXivMeta ($html_headers) {
    my $arXivRec = RefRec->new;

    my $citation_date_str = $html_headers->header('X-Meta-Citation-Online-Date');
    if (test($citation_date_str)) {
        try {
            my $date = date_parse($citation_date_str);
            $arXivRec->issued(date_conversion($date));
        }
        catch {};
    }
    elsif (test($citation_date_str
                = $html_headers->header('X-Meta-Citation-Date'))) {
        try {
            my $date = date_parse($citation_date_str);
            $arXivRec->issued(date_conversion($date));
        }
        catch {};
    }

    my $citation_title = $html_headers->header('X-Meta-Citation-Title');
    if (test($citation_title)) {
        $arXivRec->title(trim(decode_entities($citation_title)));
    }

    my @authors = $html_headers->header('X-Meta-Citation-Author');
    if (test(\@authors)) {
        for my $author_str (@authors) {
            my $author = parse_author($author_str);
            push @{$arXivRec->author}, $author;
        }
    }

    my $pdf_url = $html_headers->header('X-Meta-Citation-Pdf-Url');
    if (test($pdf_url)) {
        $arXivRec->URL(trim(decode_entities($pdf_url)));
    }

    $arXivRec->type('article');

    return $arXivRec;
}

my $arXivRec = processArXivMeta($html_headers);


# DublinCore date.

## TODO: Reinstate and improve.
# my $dc_date = $dc->date;
# if (! test($entry{'issued'})
#     && test($dc_date)
#     && test($dc_date->content)) {
#     #print STDERR "raw date: ", $dc_date->content, "\n";
#     try {
#         my $date = date_parse($dc_date->content);
#         $entry{'issued'} = date_conversion($date);
#     }
#     catch {};
# }

# HTML headers parsing.

sub processHtmlHeaderMeta ($html_headers) {
    my $htmlHeaderRec = RefRec->new;

    if (test($html_headers->header('X-Meta-Author'))) {
        my $author = parse_author($html_headers->header('X-Meta-Author'));
        push @{$htmlHeaderRec->author}, $author;
    }

    my $html_meta_date_str = $html_headers->header('X-Meta-Date');
    if (test($html_meta_date_str)) {
        #print STDERR "date: >", $html_meta_date_str, "<\n";

        try {
            my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
            $htmlHeaderRec->issued(date_conversion($date));
        }
        catch {};
    }

    $html_meta_date_str = $html_headers->header('X-Meta-Created');
    if (! test($htmlHeaderRec->issued)
        && test($html_meta_date_str)) {
        #print STDERR "date: >", $html_meta_date_str, "<\n";

        try {
            my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
            $htmlHeaderRec->issued(date_conversion($date));
        }
        catch {};
    }

    $html_meta_date_str = $tree->findvalue(
        '//head/meta[lower-case(@property)="published-date"]/@content');
    if (! test($htmlHeaderRec->issued)
        && test($html_meta_date_str)) {
        #print STDERR "date: >", $html_meta_date_str, "<\n";

        try {
            my $date = DateTime::Format::HTTP->parse_datetime($html_meta_date_str);
            $htmlHeaderRec->issued(date_conversion($date));
        }
        catch {};
    }

    my $html_meta_keywords = $html_headers->header('X-Meta-Keywords');
    if (test($html_meta_keywords)) {
        trim($html_meta_keywords);
        $html_meta_keywords =~ s/(\s)\s*/$1/g;
        $htmlHeaderRec->keyword($html_meta_keywords);
    }

    if (test($html_headers->header('X-Meta-Description'))) {
        $htmlHeaderRec->abstract(trim($html_headers->header('X-Meta-Description')));
    }

    return $htmlHeaderRec;
}

my $htmlHeaderRec = RefRec->new;
if (defined $html_headers) {
    $htmlHeaderRec = processHtmlHeaderMeta($html_headers);
}


my %entry = ();
$entry{'title'} = choose(
    $mdRec->title, $ogRec->title, $arXivRec->title, $schemaOrgJsonLd->title,
    $parselyPageRec->title, $htmlHeaderRec->title);
$entry{'type'} = choose(
    $mdRec->type, $ogRec->type, $arXivRec->type, $schemaOrgJsonLd->type,
    $parselyPageRec->type, $htmlHeaderRec->type);
$entry{'author'} = choose(
    $mdRec->author, $ogRec->author, $arXivRec->author, $schemaOrgJsonLd->author,
    $parselyPageRec->author, $htmlHeaderRec->author);
$entry{'accessed'} = date_conversion(DateTime->today());
$entry{'issued'} = choose(
    $mdRec->issued, $ogRec->issued, $arXivRec->issued,
    $schemaOrgJsonLd->issued, $parselyPageRec->issued,
    $htmlHeaderRec->issued);
$entry{'container-title'} = choose(
    $mdRec->container_title, $ogRec->container_title,
    $schemaOrgJsonLd->container_title, $parselyPageRec->container_title,
    $htmlHeaderRec->container_title);
$entry{'publisher'} = choose(
    $mdRec->publisher, $ogRec->publisher,
    $schemaOrgJsonLd->publisher, $parselyPageRec->publisher,
    $htmlHeaderRec->publisher);
$entry{'publisher-place'} = choose(
    $mdRec->publisher_place, $ogRec->publisher_place,
    $schemaOrgJsonLd->publisher_place, $parselyPageRec->publisher_place,
    $htmlHeaderRec->publisher_place);
$entry{'volume'} = choose(
    $mdRec->volume, $ogRec->volume, $schemaOrgJsonLd->volume,
    $parselyPageRec->volume, $htmlHeaderRec->volume);
$entry{'issue'} = choose(
    $mdRec->issue, $ogRec->issue, $schemaOrgJsonLd->issue,
    $parselyPageRec->issue, $htmlHeaderRec->issue);
$entry{'page'} = choose(
    $mdRec->page, $ogRec->page, $schemaOrgJsonLd->page, $parselyPageRec->page,
    $htmlHeaderRec->page);
$entry{'abstract'} = choose(
    $mdRec->abstract, $ogRec->abstract,
    $schemaOrgJsonLd->abstract, $parselyPageRec->abstract,
    $htmlHeaderRec->abstract);
$entry{'keyword'} = choose(
    $mdRec->keyword, $ogRec->keyword, $schemaOrgJsonLd->keyword,
    $parselyPageRec->keyword, $htmlHeaderRec->keyword);
$entry{'ISBN'} = choose(
    $mdRec->ISBN, $ogRec->ISBN, $schemaOrgJsonLd->ISBN, $parselyPageRec->ISBN,
    $htmlHeaderRec->ISBN);
$entry{'ISSN'} = choose(
    $mdRec->ISSN, $ogRec->ISSN, $schemaOrgJsonLd->ISSN, $parselyPageRec->ISSN,
    $htmlHeaderRec->ISSN);
$entry{'DOI'} = choose(
    $mdRec->DOI, $ogRec->DOI, $schemaOrgJsonLd->DOI, $parselyPageRec->DOI,
    $htmlHeaderRec->DOI);
$entry{'URL'} = choose(
    $mdRec->URL, $ogRec->URL, $arXivRec->URL, $schemaOrgJsonLd->URL, $parselyPageRec->URL,
    $htmlHeaderRec->URL, $ARGV[0]);

# Remove undef values from entry.
while (my ($key, $val) = each %entry) {
    delete $entry{$key} if not defined $val or not test($val);
}

print STDERR "Dump: ", Dumper(\%entry), "\n";
print "\n", YAML::Dump([\%entry]), "\n...\n";
