# ::====================================================================\ #
# | LaTeXML::Util::TestMath                                             | #
# | Testing utilities for parsing math expressions                      | #
# |=====================================================================| #
# | NOT Part of LaTeXML:                                                | #
# |  Public domain software, produced as part of work done by the       | #
# |  United States Government & not subject to copyright in the US.     | #
# |---------------------------------------------------------------------| #
# | Deyan Ginev <deyan.ginev@nist.gov>                          #_#     | #
# | http://dlmf.nist.gov/LaTeXML/                              (o o)    | #
# \=========================================================ooo==U==ooo=/ #

package LaTeXML::Util::TestMath;
use strict;
use warnings;
use Data::Dumper;
use List::MoreUtils qw/natatime/;
use Scalar::Util qw/blessed/;

use LaTeXML::Converter;
use LaTeXML::Util::Config;

use Test::More;
use Test::Deep qw/cmp_deeply supersetof/;
use LaTeXML::Util::Test;
our @ISA = qw(Exporter);
our @EXPORT = (qw(math_tests anno_string_to_array weaken_cmml parse_TeX),
  @Test::More::EXPORT);

### Test API

sub math_tests {
  my (%options) = @_;
  $options{tests} = [] unless defined $options{tests};
  my $iterator = natatime 2, @{$options{tests}};

  while (my ($input,$output) = $iterator->()) {
    my $copy = $input;
    my $array_expected = anno_string_to_array($output);
    $array_expected = weaken_cmml($array_expected,$options{type});

    my $xml_parse = parse_TeX($input,parser=>'LaTeXML::MathSyntax');
    my $array_parse = xmldom_to_array($xml_parse);
    # Unwrap the leading math/xmath if present
    while ($array_parse->[0] =~ /^ltx:X?Math$/) {
      $array_parse = $array_parse->[2]; }
    my @parse_forest = ();
    # If we're given a parse forest, deal with it appropriately
    if (($array_parse->[0] eq 'ltx:XMApp') && 
      (defined $array_parse->[1]->{meaning}) &&
      ($array_parse->[1]->{meaning} eq 'cdlf-set')) {
      @parse_forest = @$array_parse[2..scalar(@$array_parse)-1];
    } else {
      @parse_forest = ($array_parse); }
    # TODO: Figure out how to neatly test both syntax and semantics
    is_syntax(\@parse_forest, $array_expected, "\nFormula: $input\nFound Parses: ".scalar(@parse_forest));
  }
  done_testing();
}

sub is_semantics {
  my ($parse_forest, $expected, $source) = @_;
  cmp_deeply(
    [map {semantic_skeleton($_)} @$parse_forest],
    supersetof(semantic_skeleton($expected)),
    $source); }
sub is_syntax {
  my ($parse_forest, $expected, $source) = @_;
  cmp_deeply(
    [map {syntactic_skeleton($_)} @$parse_forest],
    supersetof(syntactic_skeleton($expected)),
    $source); }

### Output/annotation manipulation
# Marpa::R2 grammar converting an annotation string into a Perl array
use Marpa::R2;
my $string_to_array_grammar =
  Marpa::R2::Scanless::G->new({
    action_object  => 'CMML_Semantics',
    default_action => '::first',
    source => \(<<'END_OF_RULES'),
:start ::= Expression

Expression ::=
  Application
  | Term

Application ::=
  '(' Expression Arguments ')' action => apply assoc => group

Arguments ::= 
  Expression action => merge
  | Expression Arguments action => merge
  
Term ::= 
  Word ':' Word ':' Word action => csymbol
  || Word ':' Word action => basic_symbol
  # Special case where the lexeme is a special char :()
  || ':' ':' Word ':' Word action => csymbol
  || ':' Word ':' Word action => nolex_csymbol

Word ~ [^\s\:\(\)]+
:discard ~ whitespace
whitespace ~ [\s]+

END_OF_RULES
});

### Sub convenience routines
sub anno_string_to_array {
  my ($annotation_string) = @_;
  my $recce = Marpa::R2::Scanless::R->new( { grammar => $string_to_array_grammar } );
  $recce->read( \$annotation_string );
  my $value_ref = $recce->value;
  my $value = $value_ref ? ${$value_ref} : 'No Parse';

  return $value; }

sub weaken_cmml {
  my ($cmml_array,$type) = @_;
  return $cmml_array if (!$type || ($type eq 'semantic'));
  # For now just downgrade to XMath immediately
  return weaken_cmml_to_xmath($cmml_array,$type); }

our $xmath_name = {'apply'=>'ltx:XMApp','cn'=>'ltx:XMTok','ci'=>'ltx:XMTok','csymbol'=>'ltx:XMTok'};
our $xmath_meaning = {'eq'=>'equals'};
sub weaken_cmml_to_xmath {
  my ($array,$type) = @_;
  # For now, simple renaming would do:
  return $array unless ref $array;
  my @copy = @$array;
  my $content_head = shift @copy;
  my $head = $xmath_name->{$content_head};
  my $attributes = shift @copy;
  $attributes->{omdcd} = delete $attributes->{cd} if exists $attributes->{cd};
  my @body;
  if ($content_head eq 'csymbol') {
    my $lexeme = delete $attributes->{lexeme};
    @body = $lexeme ? ($lexeme) : ();
    $attributes->{meaning} = shift @copy; }
  elsif ($content_head eq 'cn') {
    $attributes->{meaning} = shift @copy;
    @body = $attributes->{meaning}; }
  else {
    @body = map {weaken_cmml_to_xmath($_,$type)} @copy; }
  
  my $meaning = $attributes->{meaning};
  if ($meaning && (exists $xmath_meaning->{$meaning})) {
    $attributes->{meaning} = $xmath_meaning->{$meaning}; }
  return [$head, $attributes, @body]; }

sub xmldom_to_array {
  my ($tree) = @_;
  my $class = blessed($tree);
  if ($class && ($class ne 'XML::LibXML::Text')) {
    # XML leaf, turn to array:
    my @attributelist = grep {defined} $tree->attributes();
    my $attributes = {map {$_->localname() => $_->value()} @attributelist};
    ['ltx:'.$tree->localname,$attributes,(grep {defined} map{xmldom_to_array($_)} $tree->childNodes)]; }
  else {
    (ref $tree) ? $tree->toString : $tree; }}

sub semantic_skeleton {
  my ($array_ref) = @_;
  return $array_ref unless (ref $array_ref eq 'ARRAY');
  my @copy = @$array_ref;
  my $head = shift @copy;
  my $attr = shift @copy;
  # OMCD and Meaning need to match up _ONLY_
  $attr = {omcd=>$attr->{omcd},meaning=>$attr->{meaning}};
  my @body = map {semantic_skeleton($_)} @copy;
  [$head,$attr,@body]; }
sub syntactic_skeleton {
  my ($array_ref) = @_;
  return $array_ref unless (ref $array_ref eq 'ARRAY');
  my @copy = @$array_ref;
  my $head = shift @copy;
  my $attr = shift @copy;
  # OMCD and Meaning need to match up _ONLY_
  my @body = map {syntactic_skeleton($_)} @copy;
  [$head,{},@body]; }



### Semantics
sub CMML_Semantics::new {return {}; }

sub CMML_Semantics::apply {
  my (undef, $open, $expr, $arguments, $close ) = @_;
  return ['apply',{},$expr,@$arguments]; }

sub CMML_Semantics::merge {
  my (undef, $expr, $arguments ) = @_;
  (! defined $arguments) ? [$expr] :
    (ref $arguments) ? [$expr,@$arguments] :
      [$expr,$arguments]; }

sub CMML_Semantics::csymbol {
  my (undef, $lexeme, $colon1, $cd, $colon2, $meaning) = @_;
  ['csymbol',{cd=>$cd,lexeme=>$lexeme},$meaning]; }

sub CMML_Semantics::nolex_csymbol {
  my (undef, $colon1, $cd, $colon2, $meaning) = @_;
  ['csymbol',{cd=>$cd},$meaning]; }

sub CMML_Semantics::basic_symbol {
  my (undef, $lexeme, $colon, $meaning) = @_;
  [$meaning,{},$lexeme]; }


### Input manipulation

sub parse_TeX {
  my ($tex_math,%options) = @_;
  $options{parser} //= 'LaTeXML::MathSyntax';
  my $opts = LaTeXML::Util::Config->new(
    input_limit=>100,
    whatsin=>'math',
    whatsout=>'math',
    post=>0,
    verbosity=>-2,
    mathparse=>$options{parser},
    defaultresources => 0,
    format=>'dom',
    preload=>[
      'LaTeX.pool','amsmath.sty',
      'amsthm.sty',
      'amstext.sty',
      'amssymb.sty',
      'eucal.sty',
      '[dvipsnames]xcolor.sty',]);
  my $latexml = LaTeXML::Converter->get_converter($opts);
  $latexml->prepare_session($opts);
  # Digest and convert to LaTeXML's XML
  my $response = $latexml->convert($tex_math);
  my $xmath = $response->{result};
  return $xmath;
}

1;