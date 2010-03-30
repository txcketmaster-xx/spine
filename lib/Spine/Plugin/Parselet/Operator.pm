# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

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
use Scalar::Util 'blessed';
use Spine::Key;

our ( $VERSION, $DESCRIPTION, $MODULE );
my $CPATH;

$VERSION     = sprintf( "%d", q$Revision$ =~ /(\d+)/ );
$DESCRIPTION = "Parselet::Operator, processes any operators";

$MODULE = { author      => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version     => $VERSION,
            hooks       => {
                       'PARSE/key' => [
                                 { name     => "ApplyOperators",
                                   code     => \&process_operators,
                                   provides => [ 'merge', 'applied_operators' ]
                                 } ],
                       'PARSE/key/line' => [{ name     => "DetectOperators",
                                              code     => \&parse_line,
                                              provides => ['detected_operatos']
                                            } ] } };

use constant CONTROL_PREFIX => "spine_";

sub parse_line {
    my ( $c, $line_ref, $line_no, $obj ) = @_;

    my $operators = $obj->metadata("operators");
    if ( !defined($operators) ) {
        $obj->metadata_set( "operators", ( $operators = [] ) );
    }

    my $re;

    # This allows users to have something that
    # looks like a control op in as a key value
    # i.e. _spine_replace() would be in the key as
    # spine_replace().
    $re = '_(_*' . CONTROL_PREFIX . '\w+\(.*\)\s*)';
    if ( $$line_ref =~ m/^$re$/ ) {
        $$line_ref = $1;
        return PLUGIN_SUCCESS;
    }

    # Detect legacy '=' operator and convert
    if ( $line_no == 1 && $$line_ref =~ m/^=\s*$/ ) {
        push @$operators, ["replace"];
        $$line_ref = undef;
        return PLUGIN_SUCCESS;
    }

    # Detect legacy '-' operator and convert
    if ( $$line_ref =~ m/^-(.*)/ ) {
        push @$operators, [ "remove", $1 ];
        $$line_ref = undef;
        return PLUGIN_SUCCESS;
    }

    # Detect real control ops i.e. spine_replace()
    # these will be processed by another plugin
    $re = CONTROL_PREFIX . '(\w+)\((.*)\)\s*';
    if ( $$line_ref =~ m/^$re$/ ) {
        my ( $op, $opts ) = ( $1, $2 );
        push @$operators, [ $1, $2 ];
        $$line_ref = undef;
        return PLUGIN_SUCCESS;
    }

    return PLUGIN_SUCCESS;
}

# we take any operators set along the way and apply them to the cur obj
# if there is one.
# Then we set reslult to be the final object
sub process_operators {
    my ( $c, $new_obj, $cur_obj, $result_ref ) = @_;
    # if the result ref is defined then we should do nothing
    return PLUGIN_SUCCESS if ( defined $$result_ref );

    # get + remove operators from the new object
    my $operators = $new_obj->metadata_remove("operators");

    # if there is no cur_obj then there isn't much to do
    if (!defined $cur_obj) {
        $$result_ref = $new_obj;
        return PLUGIN_SUCCESS;
    } else {
        $$result_ref = $cur_obj;
    }
    
    # add in any default operators that are kept between runs
    # these are put at the start so that the user can override
    my $default_ops = $new_obj->metadata("default_operators");
    if ( ref $default_ops eq "ARRAY" ) {
        unshift @$operators, @$default_ops;
    }

    my $new_data_ref = $new_obj->get_ref();

    # default merge/replace polocy, We unshift so that it takes lowest
    # priority making it easy for the user to override
    if (    $cur_obj->can("merge_default")
         && $cur_obj->merge_default($new_data_ref) )
    {
        unshift @$operators, ["merge"];
    } else {
        unshift @$operators, ["replace"];
    }

    # TODO: depreciate
    # Detect legacy '=' operator and convert. Normally this would happen during
    # PARSE/key/line but because comments can still exists in the key at that
    # point we have to check here as well. Eventually this can be removed
    # once people use the new format.
    if (    ref($$new_data_ref) eq "ARRAY"
         && exists ${$new_data_ref}->[0]
         && ${$new_data_ref}->[0] =~ m/^=\s*$/ )
    {
        shift @{$$new_data_ref};
        push @$operators, ["replace"];
    }

    # anythign for us to do?
    unless ( scalar(@$operators) ) {
        return PLUGIN_SUCCESS;
    }

    # the operators we will actually run
    my @final_ops;

    # Merge and replace are special cases as they have to come last
    # and only one of them makes sense. We want the last one given to
    # take effect so the user can always overried any defualts
    my $merge = undef;
    while ( my $op = shift @$operators ) {
        if ( $op->[0] eq "replace" ) {
            $merge = undef;
        } elsif ( $op->[0] eq "merge" ) {
            shift @$op;

            # we want merge to be defined even if there is
            # no options so we create an empty array ref
            $merge = exists $op->[0] ? $op : [];
        } else {
            push @final_ops, $op;
        }
    }

    my $description = $cur_obj->metadata("description") || ref($cur_obj);

    foreach my $op (@final_ops) {
        my $method = $op->[0];

        # Does the operator exists?
        unless ( $cur_obj->can($method) ) {
            $c->error( "Attempt to use unknown operator ($method) on "
                         . $description,
                       "error" );
            return PLUGIN_ERROR;
        }

        # hopefully the call to "can" above make this fairly safe...
        $cur_obj->$method( exists $op->[1] ? $op->[1] : undef );
    }

    # Finally deal with replace/merge
    if ( defined $merge ) {
        $cur_obj->merge($new_obj, @$merge);
    } else {
        $cur_obj->replace($new_obj, @$merge);
    }

    return PLUGIN_SUCCESS;
}

1;
