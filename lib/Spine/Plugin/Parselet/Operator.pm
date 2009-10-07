# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Operator.pm 251 2009-09-03 16:17:59Z richard $

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

use strict;

package Spine::Plugin::Parselet::Operator;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
### TODO Need to write out own....
#use List::MoreUtils qw(uniq);

our ( $VERSION, $DESCRIPTION, $MODULE );
my $CPATH;

$VERSION     = sprintf( "%d.%02d", q$Revision: 251 $ =~ /(\d+)\.(\d+)/ );
$DESCRIPTION = "Parselet::Operator, processes any operators";

$MODULE = {
    author      => 'osscode@ticketmaster.com',
    description => $DESCRIPTION,
    version     => $VERSION,
    hooks       => {
        'PARSE/key' => [
            { name     => "ApplyOperators",
              code     => \&process_operators,
              provides => [ 'merge', 'applied_operators' ] } ],
        'PARSE/key/line' => [
            { name     => "DetectOperators",
              code     => \&parse_line,
              provides => ['detected_operatos'] } ]
    } 
};

use constant CONTROL_PREFIX => "spine_";

use constant { HASH_KEY   => 1 << 0,
               ARRAY_KEY  => 1 << 1,
               SCALAR_KEY => 1 << 2,
               NONREF_KEY => 1 << 3,
               BLANK_KEY  => 1 << 4, };
use constant MULTI_KEY => ( HASH_KEY | ARRAY_KEY );

# Resolve ref returns into numeric versions
my %key_type = ( HASH   => HASH_KEY,
                 ARRAY  => ARRAY_KEY,
                 SCALAR => SCALAR_KEY,
                 +undef => NONREF_KEY, );

# <OPNAME> => [ <OP_FUNCREF>, <KEYTYPS> ]
# undef = a currently blank key
my %op_func = ( replace => [ \&replace_key, MULTI_KEY ],
                merge   => [ \&merge_key,   MULTI_KEY ],
                grep    => [ \&grep_key,    MULTI_KEY ],
                remove  => [ \&rgrep_key,   MULTI_KEY ], );

sub parse_line {
    my ( $c, $line_ref, $line_no, $data ) = @_;

    # Create array ref for control operators
    $data->{control} = [] unless exists $data->{control};
    my $re;

    # This allows users to have something that
    # looks like a control op in as a key value
    # i.e. _spine_replace() would be in the key as
    # spine_replace().
    $re = '_(_*' . CONTROL_PREFIX . '\w+\(.*\)\s*)';
    if ( $$line_ref =~ m/^$re$/o ) {
        $$line_ref = $1;
        return PLUGIN_SUCCESS;
    }

    # Detect legacy '=' operator and convert
    if ( $line_no == 1 && $$line_ref =~ m/^=\s*$/o ) {
        unshift @{ $data->{control} }, ["replace"];
        $$line_ref = undef;
        return PLUGIN_SUCCESS;
    }

    # Detect legacy '-' operator and convert
    if ( $$line_ref =~ m/^-(.*)/o ) {
        push @{ $data->{control} }, [ "remove", $1 ];
        $$line_ref = undef;
        return PLUGIN_SUCCESS;
    }

    # Detect real control ops i.e. spine_replace()
    # these will be processed by another plugin
    $re = CONTROL_PREFIX . '(\w+)\((.*)\)\s*';
    if ( $$line_ref =~ m/^$re$/o ) {
        push @{ $data->{control} }, [ $1, $2 ];
        next;
    }
}

# XXX: might be worth having a PARSE/key/control hook point
#      to make this more plugable... we go for speed for now...
sub process_operators {
    my ( $c, $data ) = @_;

    # Detect legacy '=' operator and convert. Normally this would happen during
    # PARSE/key/line but because comments can still exists in the key at that
    # point we have to check here as well. Eventually this can be removed
    # once people use the new format.
    if ( ref($data->{obj}) eq "ARRAY"
         && exists $data->{obj}->[0]
         && $data->{obj}->[0] =~ m/^=\s*$/o )
    {
        shift @{$data->{obj}};
        $data->{control} = [] unless exists $data->{control};
        unshift @{ $data->{control} }, ["replace"];
    }

    # anythign for us to do?
    unless ( exists $data->{control} && length( $data->{control} ) ) {
        return PLUGIN_SUCCESS;
    }

    # If there is no keyname then there will be nothing
    # for us to operate on
    return PLUGIN_SUCCESS
      unless ( exists $data->{keyname}
               && defined $data->{keyname} );
    my $keyname = $data->{keyname};

    # What type are we putting in place
    my $objtype = $key_type{ ref( $data->{obj} ) };

    # get the current key content, ops are pointless without it
    my $current_key = $c->getkey($keyname);
    return PLUGIN_SUCCESS unless defined $current_key;
    my $keytype = $key_type{ ref($current_key) };

    # If both are arrays then we add in a merge by default here
    # If the user doesn't want this they have to use replace
    # to clear out the src so that this will do nothing
    if ( $keytype == ARRAY_KEY && $objtype == ARRAY_KEY ) {
        push @{ $data->{control} }, ["merge"];
    }
 

    foreach my $op ( @{ $data->{control} } ) {

        # Does the operator exists?
        unless ( exists $op_func{ $op->[0] } ) {
            $c->error( "Attempt to use a key operator that we don't know."
                         . " key = ($keyname) operator = ($op->[0]).",
                       "error" );
            next;
        }

        # Does the operator support this type of key?
        unless ( $keytype & $op_func{ $op->[0] }->[1] ) {

            # TODO shorten this error message
            $c->error(
                     "Attempt to use key operator \"$op->[0]\" on \"$keyname\" "
                       . "which is an unsupported key type \""
                       . ref($current_key) . "\".",
                     "error" );
        }

        # Call the operator func, it's up to it to alter the object if needed
        # the return goes into.
        $current_key =
          &{ $op_func{ $op->[0] }->[0] }( $c, $keytype, $current_key, $objtype,
                                          $data, $op->[1] );
    }

    return PLUGIN_SUCCESS;
}

# Simple function that will clear out the current key
sub replace_key {
    my ( $c, $ktype, $ckey, $otype, $data, $opts ) = @_;

 
    $c->print(4, "replaceing the \"$data->{keyname}\" key");
    return {} if $ktype == HASH_KEY;
    return [] if $ktype == ARRAY_KEY;
    return undef;
}

sub merge_key {
    my ( $c, $ktype, $ckey, $otype, $data, $opts ) = @_;


    # We can only merge the same types
    unless ( $ktype eq $otype) {
        $c->error( "Attempt to merge \"$data->{source}\" into \"$data->{keyname}\" of wrong type",
                   "error" );
        return $ckey;
    }

    # If the key has no length then no point merging.
    #return $ckey unless scalar(@$ckey);

    $c->print( 4, "mergeing \"$data->{source}\" into the \"$data->{keyname}\" key" );

    # Split out any options
    $opts = { map { chomp($_); $_ => undef } split( ",", $opts ) };

    if ( $ktype == HASH_KEY ) {
        if ( exists $opts->{reverse} ) {
            $data->{obj} = { %{ $data->{obj} }, %{$ckey} };
        } else {
            $data->{obj} = { %{$ckey}, %{ $data->{obj} } };
        }
        return {};
    }

    if ( $ktype == ARRAY_KEY ) {
        if ( exists $opts->{reverse} ) {
            push @{ $data->{obj} }, @{$ckey};
        } else {
            unshift @{ $data->{obj} }, @{$ckey};
        }
        #### TODO: write unique func
        #@{$data->{obj}} = uniqu(@{$data->{obj}}) if exists $opts->{uniqu};
    }
}

sub grep_key {
    my ( $c, $ktype, $ckey, $otype, $data, $opts ) = @_;

    $c->print( 4, "greppping \"$opts\" from the \"$data->{keyname}\" key" );

    return [ grep /$opts/, @{$ckey} ] if $ktype == ARRAY_KEY;

    foreach ( keys %$ckey ) {
        delete $ckey->{$_} unless $_ =~ m/$opts/;
    }
    return $ckey;
}

sub rgrep_key {
    my ( $c, $ktype, $ckey, $otype, $data, $opts ) = @_;

    $c->print( 4, "removing \"$opts\" from the \"$data->{keyname}\" key" );

    return [ grep !/$opts/, @{$ckey} ] if $ktype == ARRAY_KEY;

    foreach ( keys %$ckey ) {
        delete $ckey->{$_} if $_ =~ m/$opts/;
    }
    return $ckey;
}

1;
