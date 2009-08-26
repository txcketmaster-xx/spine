# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
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

package Spine::Plugin::Auth;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Identity Management and Auththentication/Authorization module";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/complete' => [ { name => 'parse_auth_data',
                                               code => \&parse_auth_data } ],
                       EMIT => [ { name => 'emit_auth_data',
                                   code => \&emit_auth_data } ]
                     },
          };


use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Spec::Functions;
use File::stat;
use Spine::Util qw(mkdir_p);

use constant {
    ACCT_TYPE_ROLE   => 1 << 1,
    ACCT_TYPE_PERSON => 1 << 2,
    ACCT_TYPE_SYSTEM => 2 << 3,
};

use constant SHADOW_STATIC => '12601:0:99999:7:::';
use constant CMDLINE => '/proc/cmdline';

use constant {
    CHECK_TYPE_INT => 0,
    CHECK_TYPE_STR => 1
};

our ($DEPTH, $MAX_DEPTH, $AUTH);

$DEPTH = 0;
$MAX_DEPTH = 7;

my @STD_FIELDS = qw(gecos gid group homedir keyopts primary_group shadow shell
                    skeldir permissions);
my @PASSWD_FIELDS = qw(gecos homedir shadow shell uid gid);


sub parse_auth_data
{
    my $c = shift;
    my $c_root = $c->getval('c_croot');
    my %auth = (accounts => { TYPES => { role => ACCT_TYPE_ROLE,
                                         person => ACCT_TYPE_PERSON,
                                         system => ACCT_TYPE_SYSTEM } },
                auth_groups => {},
                uid_map => { by_id => {}, by_name => {} },
                gid_map => { by_id => {}, by_name => {} },
                user_map => {},
                group_map => {},
                auth_type => ''
               );

    #
    # Pull in our auth_type for this run.
    #

    my $special = $c->getvals('special_auth_types');

    if (defined($special)) {
        my %special_hash = map { $_ => undef } @{$special};
        my $auth_type = $c->getval_last('auth_type');

        if (defined($auth_type) and exists($special_hash{$auth_type})) {
            $auth{auth_type} = '_' . $auth_type;
        }

        undef %special_hash;
        undef $auth_type;
    }
    undef $special;

    # Pull in the uid/gid maps
    _parse_maps($c, \%auth, catfile($c_root, 'auth'));

    #
    # We parse auth_groups first, then walk the allowed_unix_users and
    # allowed_unix_groups lists and fully normalize them both, THEN we can
    # parse in only those accounts that are needed for this machine.  The
    # added bonus is that mistakes in files unrelated to the machine Spine is
    # running on at the time prevent other problems.
    #

    # Build the auth_group structure
    $auth{auth_groups} =_parse_auth_groups($c,
                                           catfile($c_root,
                                                   qw(auth auth_groups)));

    # Build the user map for this machine
    $auth{user_map} = _build_user_map($c, $auth{auth_groups});

    unless (defined($auth{user_map})) {
        die('Failed to populate user map!');
    }

    #
    # Build the account structure
    #

    _parse_auth_data($c, \%auth, catfile($c_root, 'auth'));

    # And sanity check what we've parsed against the user map
    my $errors = _sanity_check_user_map($c, \%auth);

    if ($errors) {
        die("$errors errors found during sanity check of accounts.");
    }

    # Build our group map
    $auth{group_map} = _build_group_map($c, \%auth);

    unless (defined($auth{group_map})) {
        die ('Failed to populate group map!');
    }

    $c->set(c_auth => new Spine::Plugin::Auth::Wrapper());
    $AUTH = \%auth;

    return PLUGIN_SUCCESS;
}


#
# This is an abstraction of walking the /auth tree
# so we can call it for each part of the /auth tree
#
# Because the format of this tree is different, we have to
# re-implement a bit of the key-reading logic from Data.pm,
# however, we re-use it's internal functions as much as possible
# to get as much code reuse as possible.
#
sub _parse_auth_data
{
    my ($c, $auth_ref, $directory) = @_;

    my $accounts_ref = $auth_ref->{accounts};
    my $user_map = $auth_ref->{user_map};

    return 0 unless ( -d $directory and -d catfile($directory, 'roles')
                      and -d catfile($directory, 'people'));

    #
    # Build the list of files we need to parse
    #
    # Why do we use a hash?  We want a list of the unique account names to
    # parse.  Since role and person accounts can't collide, we know that if we
    # have a list of unique account names and manage to parse a role account
    # first then we can't have a collision.
    #
    # What do we do here?  We walk the two level user map hash in order to
    # flatten and unique-ify it so we only attempt to parse each named account
    # once.  The keys of %accts_to_parse are those accounts and are unique
    # because %accts_to_parse is a hash.
    #
    my %accts_to_parse = ();
    while (my ($k, $v) = each(%{$user_map})) {
        $accts_to_parse{$k} = undef;

        if (defined($v)) {
            foreach my $k2 (keys(%{$v})) {
                $accts_to_parse{$k2} = undef;
            }
        }
    }

    my %missing;

    foreach my $keyname (keys(%accts_to_parse)) {
        my $type = ACCT_TYPE_ROLE;
        my $keyfile = catfile($directory, 'roles', $keyname);

        # Determine account type
        if (-f catfile($directory, 'roles', $keyname)
            and -r catfile($directory, 'roles', $keyname)) {
            $type = ACCT_TYPE_ROLE;
            $keyfile = catfile($directory, 'roles', $keyname);
        } elsif (-f catfile($directory, 'people', $keyname)
                 and -r catfile($directory, 'people', $keyname)) {
            $type = ACCT_TYPE_PERSON;
            $keyfile = catfile($directory, 'people', $keyname);
        } else {
            $c->error("Can't find \"$keyname\" entry for reading", 'crit');
            $missing{$keyname} = undef;
            next;
        }

        my $values = $c->read_keyfile($keyfile);

        # read_keyfile() returns an undef when there's an error
        unless (defined($values)) {
            $c->error("Spine::Data::read_keyfile() failed on $keyfile!",
                      'crit');
            die('Bad data');
        }

        my $acct_ref = { acct_type => $type };

        foreach my $value (@{$values}) {

            # This chunk of code does the replacement of
            # <$var> stuff the way the rest of spine does
            # it. It's stolen from Data.pm.
            my $regex = '(?:<\$([\w_-]+)>)';
            foreach my $match ( split(/$regex/, $value) ) {
                next unless (exists $c->{$match});
                my $replace = $c->getval($match);
                $value =~ s/$regex/$replace/;
            }

            #
            # Here it's a simple assignment, unless we're dealing
            # with key (or key_*) or group (or group_*), in
            # which case multiple values are allowed, so we
            # push it onto an array.
            #
            my ($key,$val,$extra) = split(/:\s*/, $value);
            if ($extra ne '') {
                $c->error('spurious colon where key:value pair expected while '
                          . "parsing $keyfile", 'crit');
                die('Bad Data');
            }
            if ($key =~ /^(key|group)(_.*)?$/) {
                unless (exists($acct_ref->{$key})) {
                    $acct_ref->{$key} = [];
                }
                push(@{$acct_ref->{$key}}, $val);
            }
            elsif ($key eq 'type') {
                if ($val eq 'system') {
                    $acct_ref->{acct_type} = ACCT_TYPE_SYSTEM;
                }
                elsif ($val eq 'person') {
                    $acct_ref->{acct_type} = ACCT_TYPE_PERSON;
                }
                elsif ($val eq 'role') {
                    $acct_ref->{acct_type} = ACCT_TYPE_ROLE;
                }
                else {
                    die("Bad data: invalid account type for user $keyname");
                }
            }
            else {
                $acct_ref->{$key} = $val;
            }
        }

        # Now some massaging

        # If shadow is blank, replace with an "x"
        if ($acct_ref->{shadow} eq '') {
            $acct_ref->{shadow} = 'x';
        }

        $accounts_ref->{$keyname} = $acct_ref;
    }

    if (scalar(keys(%missing))) {
        die('Bad data on ' . join(', ', keys(%missing)) );
    }
}


#
# You guessed it, this is similar to the above function,
# more key-reading logic. This time we're not parsing the
# values in each key.
#
sub _parse_auth_groups
{
    my ($c, $directory) = @_;

    return 0 unless( -d $directory );

    my $groups = {};

    foreach my $keyfile (<$directory/*>) {

        my $keyname = basename($keyfile);

        my $values = $c->read_keyfile($keyfile);

        # read_keyfile() returns an undef when there's an error
        unless (defined($values)) {
            $c->error("Spine::Data::read_keyfile() failed on auth_groups/$keyname!",
                      'crit');
            die('Bad data');
        }

        foreach my $value (@{$values}) {
            if ($value =~ m/:/) {
                $c->error("spurious colon in auth_group $keyfile", 'crit');
                die('Bad Data');
            }

            unless (exists($groups->{$keyname})) {
                $groups->{$keyname} = [];
            }

            push(@{$groups->{$keyname}}, $value);
        }
    }

    return $groups;
}


sub _parse_maps
{
    my ($c, $auth_ref, $directory) = @_;

    return 0 unless( -d $directory );

    for my $map_type (qw(uid gid)) {
        my $map = $map_type . '_map';
        my $by_id = $auth_ref->{$map}->{by_id};
        my $by_name = $auth_ref->{$map}->{by_name};
        my $keyfile = "$directory/$map";
        my $keyname = basename($keyfile);

        my $values = $c->read_keyfile($keyfile);

        # read_keyfile() returns an undef when there's an error
        unless (defined($values)) {
            $c->error("Spine::Data::read_keyfile() failed on $map!", 'crit');
            die('Bad data');
        }

        foreach my $value (@{$values}) {
            my @list = split(m/:/o, $value);

            if (scalar(@list) != 2) {
                $c->error("Invalid line in $map: \"$value\"", 'crit');
                die('Bad data');
            }

            my ($id, $name) = @list;
            $id = int($id);

            # Beware of collisions
            if (exists($by_id->{$id})) {
                $c->error("ID collision detected in $map: \"$value\" is "
                          . "already assigned to \"" . $by_id->{$id} . '"',
                          'crit');
                die('Bad data');
            }

            if (exists($by_name->{$name})) {
                $c->error("Name collision detected in $map: \"$value\" is "
                          . "already assigned ID \"" . $by_name->{$name} . '"',
                          'crit');
                die('Bad data');
            }

            $by_id->{$id} = $name;
            $by_name->{$name} = $id;
        }
    }
}


# Handles any recursion for '@' group expansion
sub _expand_auth_group
{
    my $c = shift;
    my $auth_groups = shift;
    my @groups_to_expand = @_;

    my @list = ();

    if (++$DEPTH > $MAX_DEPTH) {
        $c->error("Nested too deep($DEPTH levels) in auth group expansion for: "
                  . join(' ', @groups_to_expand), 'err');
        --$DEPTH;
        goto group_error;
    }

    foreach my $group (@groups_to_expand) {
        unless (exists($auth_groups->{$group})) {
            $c->error("Invalid auth_group definition: \"$group\"", 'err');
            goto group_error;
        }

        unless (scalar(@{$auth_groups->{$group}})) {
            $c->error("auth_group $group is empty, so is being dropped",
                      'warning');
            next;
        }

        push @list, @{$auth_groups->{$group}};

        #
        # Grep all further groups, pass in at once, limit recursion
        #
        my @nested_groups = grep(m/^@/o, @{$auth_groups->{$group}});

        if (scalar(@nested_groups)) {
            push @list, _expand_auth_group($auth_groups, $group);
        }
    }

    # Now we eliminate any dupes
    my %list = map { $_ => undef } @list;

    if (--$DEPTH < 0) {
        $c->error("auth group expansion recursion busted: $DEPTH", 'err');
        goto group_error;
    }

    return wantarray ? keys(%list) : \%list;

 group_error:
    return wantarray ? () : undef;
}


sub _build_user_map
{
    my ($c, $auth_groups) = @_;

    #
    # First we create a simpler structure so that we
    # can easily get all "people" under their UNIX users.
    #
    # %user_map => {
    #           'phil' => undef,  # individual user account
    #           'root' => {       # role account
    #                   'phil' => undef,
    #                   'rafi' => undef,
    #                   },
    #           ...
    #           }
    #
    #

    my %user_map;
    foreach (@{$c->getvals('allowed_unix_users') || []}) {
        my ($key,$val,$extra) = split(/:/);
        #$c->error("Found pair: $key $val",'debug');
        if ($extra ne '') {
            $c->error('Spurious colon found where key:value pair expected '
                      . " while parsing allowed_unix_users entry $_", 'crit');
            die('Bad data');
        }
        undef $extra;

        #
        # We error here on an empty val only since empty
        # keys are sometimes valid
        #
        if ($val =~ m/^(\@)?$/) {
            $c->error('Empty RHS in allowed_unix_users not permitted'
                      . " ($key:$val)", 'crit');
            die('Bad data');
        }

        # FIXME  I think this is some broken syntax.  ":@foo"?  Why bother with
        #        the colon?  Just eliminate it.
        #
        # :@foo is a valid syntax denoting local users for all
        # people in @foo, soo key can be empty only in this case.
        #
        if ($key eq '' && $val !~ /^\@/) {
            $c->error('Empty LHS in allowed_unix_users not permitted unless'
                      . " RHS is an auth_group: ($key:$val)", 'crit');
            die('Bad data');
        }

        #
        # If we have an auth_group (e.g. "@websys"), we need
        # to resolve that to a list of people and push those
        # people onto the allowed_users list for future iterations
        #
        if ($val =~ m/^\@/) {

            # Using split to get the second value
            my (undef,$group) = split(/\@/,$val);

            my $list_ref = _expand_auth_group($c, $auth_groups, $group);

            unless (defined($list_ref)) {
                $c->error("Failed to expand group \"$val\" for user "
                          . "\"$key\"", 'crit');
                die('Bad data');
            }

            # If it's of the form ":@foo" then just append the list of accounts
            # to the %user_map hash
            if ($key eq '') {
                foreach my $person (keys(%{$list_ref})) {
                    $user_map{$person} = undef;
                }
            }
            else {
                unless (defined($user_map{$key})) {
                    $user_map{$key} = {};
                }

                foreach my $new_user (keys(%{$list_ref})) {
                    $user_map{$key}->{$new_user} = undef;
                }
            }

            next;
        }

        # Otherwise it's just a simple one to one assignment

        if ($key eq $val) {
            # If it's an individual account, denote it with an undef
            $user_map{$key} = undef;
            next;
        } else {
            # Otherwise, we use a hash to list the users uniquely
            unless (defined($user_map{$key})) {
                $user_map{$key} = {};
            }
            $user_map{$key}->{$val} = undef;
        }
    }

    return \%user_map;
}


sub _sanity_check_user_map
{
    my ($c, $auth_ref) = @_;

    my $accounts = $auth_ref->{accounts};
    my $user_map = $auth_ref->{user_map};
    my $uid_map  = $auth_ref->{uid_map};
    my $gid_map  = $auth_ref->{gid_map};

    my $errors = 0;

    #
    # You can't have 'role:role' - the RHS MUST be a person or group of
    # people.
    #
    # The restructure of auth won't catch this at parse-time, and if we don't
    # catch it here, we have undefined behavior.
    #
    foreach my $line (@{$c->getvals('allowed_unix_users') || []}) {
        my ($key, $val) = split(':', $line, 2);

        # We don't have to check for 3 colons, we've already checked for it
        # in _parse_auth_data()

        if (_get_account_type($val, $accounts) == ACCT_TYPE_ROLE) {
            $c->error("attempting to add a role account to a role"
                . " account: $line", 'crit');
            die('Bad data');
        }
    }

    while (my ($key, $val) = each(%{$user_map})) {

        #
        # Check to make sure we have info on everyone in the %user_map
        #
        unless (exists($accounts->{$key})) {
            $c->error("LHS of allowed_users ($key:$val) doesn't map to"
                      . ' any account (role or person)', 'crit');
            $errors++;
            next;
        }

        #
        # Before we do anything else we want to determine
        # the account type (role or person) since we
        # allow certain actions on roles that we don't
        # on individual accounts.
        #
        my $account_type = _get_account_type($key, $accounts);
        if (!defined($account_type)) {
            #
            # Note here that we already check for key eq "" above
            # so if it's blank, that's valid (":@foo"), so we don't
            # care about that case, we only care about non-blanks
            # that don't match
            #
            # Also note that keys in $user_map are LHS's of allowed_unix_users
            #
            $c->error("$key used on the LHS of an allowed_unix_users line, but"
                      . " is neither a role nor a person ($key:val)", 'crit');
            $errors++;
        } elsif ($account_type == ACCT_TYPE_ROLE) {
            # Walk the list of users and make sure they exist
            foreach my $baby (keys(%{$val})) {
                unless (exists($accounts->{$baby})) {
                    $c->error("Invalid inclusion for \"$key\": \"$baby\"",
                              'crit');
                    $errors++;
                    next;
                }

                # Now we walk the hash
                my $a_t = _get_account_type($baby, $accounts);
                unless ($a_t == ACCT_TYPE_PERSON) {
                    $c->error("RHS of allowed_users \"$baby\" doesn't map to"
                              . ' a person', 'crit');
                    $errors++;
                }
            }
        } else {
            #
            # If we're creating an individual or system account, the
            # only valid syntax is "person:person"
            #
            if (defined($val)) {
                $c->error("You're attempting to assign to a individual's "
                          . "account(\"$key\").  This is only permitted for "
                          . 'role accounts.', 'crit' );
                $errors++;
            }
        }

        #
        # Take existing data, grep through the uid/gid-maps,
        # and come up with UID/GID

        my $potential_uid = $uid_map->{by_name}->{$key};

        unless (defined($potential_uid)) {
            $c->error("Can't map $key to a UID", 'crit');
            $errors++;
        }

        $accounts->{$key}->{uid} = $potential_uid;

        my $potential_gid =
            $gid_map->{by_name}->{$accounts->{$key}->{primary_group}};

        unless (defined($potential_gid)) {
            $c->error("Can't map $key primary group"
                      . " ($accounts->{$key}->{primary_group}) to a GID",
                      'crit');
            $errors++;
        }

        $accounts->{$key}->{gid} = $potential_gid;

        #
        # Special case shadow handling for root
        #
        if ($accounts->{$key}->{uid} == 0 and $key eq 'root') {
            my $shadow = $c->getval_last('shadow_root');

            if (defined($shadow) and $shadow ne '') {
                $accounts->{$key}->{shadow} = $shadow;
            }
            else {
                $c->error('shadow_root appears to be undefined or empty!  Not '
                          . 'good!', 'err');
                $errors++;
            }
        }

        #
        # Sanity Checking
        # While homedir and gecos can technically be missing
        # we intend to use gecos for user identification,
        # and we don't ever want homedir left blank. So here
        # we check all passwd/shadow fields for blanks.
        #
        # We don't check for spurious colons as the Data plugin
        # is splitting on colons, so you can't get 'em in
        # anyway.
        #
        foreach my $field (@PASSWD_FIELDS) {
            if ($accounts->{$key}->{$field} eq '') {
                $c->error("Field $field missing for $key", 'crit');
                $errors++;
            }
        }

    }

    return $errors;
}


sub _build_group_map
{
    my ($c, $auth_ref) = @_;

    my $accounts  = $auth_ref->{accounts};
    my $user_map  = $auth_ref->{user_map};
    my $gid_map   = $auth_ref->{gid_map};
    my $auth_type = $auth_ref->{auth_type};

    my %group_map;
    my $account_type;

    # First, walk through the allowed_unix_groups to initially populate our
    # group map
    foreach my $group (@{$c->getvals('allowed_unix_groups') || []}) {
        unless (exists($group_map{$group})) {
            $group_map{$group} = {};
        }
    }

    # Second, make sure we include any necessary additional groups for the
    # accounts that we're going to create
    foreach my $user (keys(%{$user_map})) {
        #
        # lets make sure our primary group is an allowed
        # groups - if not, we'll add it, and warn. This
        # is the only place we "try to fix stuff" and we
        # only do it because it's straight forward what
        # the desired behavior is. We try not to be implicit
        # anywhere else to avoid adding unwanted access
        #

        my $primary_group = '';
        if (exists($accounts->{$user}->{'primary_group' . $auth_type})) {
            $primary_group = $accounts->{$user}->{
                'primary_group' . $auth_type};
        } else {
            $primary_group = $accounts->{$user}->{primary_group};
        }

        unless (exists($group_map{$primary_group})) {
            $c->error("Adding $user's primary group \"$primary_group\" to the "
                      . ' allowed_groups list', 'warning');
            $group_map{$primary_group} = {};
        }

        #
        # This assignment works in the same way that $primary_group does above
        #
        my $glist = '';
        if (exists($accounts->{$user}->{'group' . $auth_type})) {
            $glist = $accounts->{$user}->{'group' . $auth_type};
        } elsif (exists($accounts->{$user}->{group})) {
            $glist = $accounts->{$user}->{group};
        }

        #
        # Loop through all their groups and add them to that group in group_map
        # - but only if it's already in the map (which was built from
        # allowed_unix_groups + primary groups)
        #
        if ($glist ne '') {
            foreach my $group (@{$glist}) {
                if (exists($group_map{$group})) {
                    $group_map{$group}->{$user} = undef;
                }
            }
        }
    }

    #
    # Lastly, populate the GIDs
    #
    # We don't really need this, and it's inconsistent, but we throw
    # gid in here just for quick reference. It's also useful for sorting
    # the group list.
    #
    while (my ($group, $map) = each(%group_map)) {
        $map->{_gid} = $gid_map->{by_name}->{$group};

        unless (defined($map->{_gid})) {
            $c->error("Can't map group \"$group\" to a GID", 'crit');
        }
    }

    return \%group_map;
}


sub _get_account_type
{

    my ($account, $accounts_ref) = @_;

    unless (exists($accounts_ref->{$account})
            and defined($accounts_ref->{$account})) {
        return undef;
    }

    return $accounts_ref->{$account}->{acct_type};
}

#
# END PARSE
#


#
# EMIT
#

sub emit_auth_data
{
    my $c = shift;

    my $min_root_keys = $c->getval_last('min_root_keys') || 3;

    #
    # Coresys can't keep their users straight and don't want to be
    # reminded about it by spine.
    #
    my $extra_checks_warn_only = 0;
    if ($c->getval_last('auth_extra_checks_warn_only')) {
        $extra_checks_warn_only = 1;
    }

    if (open(CMD, CMDLINE)) {
        my $cmdline = <CMD>;
        close(CMD);
        if ($cmdline =~ /auth_extra_checks_warn_only/) {
            $extra_checks_warn_only = 1;
        }
    }

    #
    # Make sure we have a real tmpdir - if it's blank
    # we'd write directly to the real FS
    #
    my $tmpdir = $c->getval('c_tmpdir');
    my $tmplink = $c->getval('c_tmplink');
    if ( $tmpdir eq '' || $tmplink eq '' ) {
        $c->error("What's my tempdir?", 'crit');
        return PLUGIN_FATAL;
    }

    #
    # "standalone mode" means when the only entry in $c->{actions} is the auth
    # module, so build_overlay doesn't have the opportunity to create the
    # overlay directory structure.
    #
    # If we're in standalone mode, mention it and create tmpdir/tmplink
    #
    if ( ! -d $tmpdir ) {
        $c->cprint('Running in stand-alone mode, creating tmpdir');
        unless (mkdir_p(catfile($tmpdir, qw(etc ssh authorized_keys), 0755)))
        {
            $c->error('could not create temp directory', 'crit');
            return PLUGIN_FATAL;
        }
        unlink $tmplink if (-l $tmplink);
        symlink($tmpdir, $tmplink);
    }


    #
    # get a list of the UIDs and GIDs of running processes
    # we use a hash again because we only care about uniques
    #
    my (%running_uids, %running_gids);
    foreach my $pid (</proc/[0-9][0-9]*>) {
        my $st = stat($pid);

        unless (defined($st)) {
            # Files in /proc often go away before we stat them,
            # so we need to watch for that.
            next;
        }

        $pid = int(basename($pid));

        unless (exists($running_uids{$st->uid})) {
            $running_uids{$st->uid} = [];
        }
        push (@{$running_uids{$st->uid}}, $pid);

        unless (exists($running_gids{$st->gid})) {
            $running_gids{$st->gid} = [];
        }
        push (@{$running_gids{$st->gid}}, $pid);
    }

    #
    # and a list of users owning crontabs
    #
    my %cron_users;
    foreach my $cronuser (</var/spool/cron/*>) {
        my $user = basename($cronuser);
        if ($user =~ /^tmp\.\d+/) {
            # Skip temporary files from cron
            next;
        }
        $cron_users{$user} = 1;
    }

    #
    # and compare them to what we're installing
    #
    my $retval = _grep_hash_element($c, \%running_uids, 'uid',
                                    $AUTH->{user_map}, CHECK_TYPE_INT,
                                    'processes');

    $retval += _grep_hash_element($c, \%running_gids, 'gid',
                                  $AUTH->{group_map}, CHECK_TYPE_INT,
                                  'processes');

    $retval += _grep_hash_element($c, \%cron_users, 'user', $AUTH->{user_map},
                                  CHECK_TYPE_STR, 'crontabs');

    if ($retval > 0) {
        if ($extra_checks_warn_only) {
            $c->error('Found running processes or crons with UIDs/GIDs not being'
                    . ' installed on this system - but carrying on due to'
                    . ' \'auth_extra_checks_warn_only\' key','warning');
        } else {
            return PLUGIN_FATAL;
        }
    }

    undef %running_uids;
    undef %running_gids;
    undef %cron_users;

    #
    # This is basically a duplicate of the user structure that was previously
    # being created in Spine::Data::auth and was provided to this action as
    # $AUTH->{users}.  The only exceptions are that this is a two level
    # hash, rather than a list of hashes with a "unix_name" field and that I've
    # removed the "key" field because I don't want those populated quite that
    # way to start.
    #
    # I've moved its creation here because I want to have the data plugin half
    # of the auth module soon become a queryable object that can provide useful
    # information to other plugins and actions.  At some time in the future,
    # I'll probably wind up moving this creation back into the data plugin
    # and make it accessable via a method like $AUTH->machine_accounts()
    #
    # At the moment, though, this action is the only thing that will need a
    # list of the accounts.  The truth is that with an easily accessable user
    # structure, generation of the files themselves become unnecessary because
    # that's what templates are for.
    #
    # rtilder    Thu Jul 27 10:57:03 PDT 2006

    my %accounts;

    foreach my $user (keys(%{$AUTH->{user_map}})) {
        my %acct;

        foreach my $field (@STD_FIELDS) {
            my $value = _get_user_auth_data($user, $field,
                                            $AUTH->{accounts},
                                            $AUTH->{auth_type});

            $acct{$field} = $value;
        }

        $acct{uid} = $AUTH->{uid_map}->{by_name}->{$user};

        $acct{gid} = $AUTH->{group_map}->{
                                $acct{primary_group}}->{_gid};

        $accounts{$user} = \%acct;
    }

    #
    # Believe it or not, all we've done thus far is build
    # complex data structures. Now we pass those structures
    # to a few small functions that do actual work.
    #
    if (($retval = _generate_passwd_shadow_home($c, $tmpdir, \%accounts)) != 0) {
        $c->error("Encountered $retval errors generating passwd/shadow/home",
                  'crit');
        return PLUGIN_FATAL;
    }

    if (($retval = _generate_group($c, $tmpdir)) != 0) {
        $c->error("Encountered $retval errors generating group file", 'crit');
        return PLUGIN_FATAL;
    }

    if (($retval =_generate_authorized_keys($c, $tmpdir, $min_root_keys,
                                            \%accounts)) != 0) {
        $c->error("Encountered $retval errors generating authorized_keys files",
                  'crit');
        return PLUGIN_FATAL;
    }

    return PLUGIN_SUCCESS;
}


#
# Check uids/gids against running procs
#
# More specifically, give a list of IDs (the keys of the hash_ref),
# that id (a UID or GID) exists in $map_ref (UID map or GID map)
#
sub _grep_hash_element
{
    my ($c,$hash_ref,$type,$map_ref,$cmp_type,$what) = @_;
    my $errors = 0;
    my $id_map = $AUTH->{$type . '_map'}->{by_id};

    foreach my $id (keys(%{$hash_ref})) {
        my $installing = 0;

        if ($cmp_type == CHECK_TYPE_INT) {
            $installing = exists($map_ref->{$id_map->{$id}});
        }
        elsif ($cmp_type == CHECK_TYPE_STR) {
            $installing = exists($map_ref->{$id});
        }
        else {
            $c->error('API for _grep_hash_element misused - cmp_type set to'
                      . ' something other than int or string.', 'crit');
            return PLUGIN_FATAL;
        }

        unless ($installing) {
            $c->error(uc($type) . " $id owns $what, but is not"
                      . ' being installed on the system', 'err');
            $errors++;
        }

    }

    return $errors;
}


#
# The rest of the functions here impliment change based on the structures
# we have built. They return, much like spine actions, the number of
# errors that were encoutered.
#
sub _generate_passwd_shadow_home
{
    my ($c, $tmpdir, $accounts) = @_;

    #
    # Make a hash of undef's. There's only undef per perl
    # parser so we're not wasting space and we're implimenting
    # an array with enforced uniqueness.
    #
    my %system_homedirs = map { $_ => undef }
            @{$c->getvals('auth_system_homedirs')};

    #
    # A few hardcoded ones
    #
    $system_homedirs{'/'} = undef;
    $system_homedirs{'/root'} = undef;
    $system_homedirs{'/var/empty/sshd'} = undef;

    my $root_found = 0;
    my $sshd_found = 0;

    foreach my $user (keys(%{$accounts})) {
        # note when we find root or sshd, the two REALLY important accounts
        $root_found = 1 if ($user eq 'root' and $accounts->{$user}->{uid} == 0);
        $sshd_found = 1 if ($user eq 'sshd');
    }

    if ($root_found == 0) {
        $c->error("There's no root user to protect me, I'm scared!"
                  . " Bailing out.",'crit');
        return PLUGIN_FATAL;
    }

    if ($sshd_found == 0) {
        $c->error("There's no sshd user to grant us our special access,"
                  . " I'm scared. Bailing out.",'crit');
        return PLUGIN_FATAL;
    }

    #
    # We want to sort it so that we get a consistent order
    #
    my @uid_ordered_users = sort {
        int($accounts->{$a}->{uid}) <=> int($accounts->{$b}->{uid});
    } keys(%{$accounts});

    #
    # Sanity checking
    #
    unless (scalar(@uid_ordered_users)) {
        $c->error("I have a blank passwd or shadow file, can't continue",
                  'crit');
        return PLUGIN_FATAL;
    }

    #
    # Open both files so that we only have to walk through the list once.
    #
    my $filename = catfile($tmpdir, qw(etc passwd));
    unless (open(PASSWD, "> $filename"))
    {
        $c->error("couldn't open $filename: $!",'crit');
        return PLUGIN_FATAL;
    }
    chown(0, 0, $filename);
    chmod(0444, $filename);

    $filename = catfile($tmpdir, qw(etc shadow));
    unless (open(SHADOW, "> $filename"))
    {
        $c->error("couldn't open $filename: $!",'crit');
        return PLUGIN_FATAL;
    }
    chown(0, 0, $filename);
    chmod(0400, $filename);

    #
    # Emit!
    #
    my ($p_count, $s_count, $p_errors, $s_errors, $h_errors) = (0, 0, 0, 0, 0);

    foreach my $user (@uid_ordered_users) {
        my $acct = $accounts->{$user};

        unless (print PASSWD join(':', $user, 'x', $acct->{uid},
                                  $acct->{gid}, $acct->{gecos},
                                  $acct->{homedir}, $acct->{shell}), "\n")
        {
            $p_errors++;
        }
        $p_count++;

        unless (print SHADOW join(':', $user, $acct->{shadow},
                                  SHADOW_STATIC), "\n")
        {
            $s_errors++;
        }
        $s_count++;

        my $dir = catfile($tmpdir, $acct->{homedir});

        # 
        # If the account has specific permissions use those
        # otherwise use the value of the default_homedir_perms key
        # if set, finally use the code default of 0700 if no other
        # perms exists.
        #
        if (defined $acct->{permissions})
        {
            my $perm = $acct->{permissions};
            mkdir_p($dir, oct($perm));
        }
        else
        {
            my $perm = $c->getval('auth_default_homedir_perms') || qq(0700);
            mkdir_p($dir, oct($perm));
        }
		
        #
        # As a default, we chown it to root - we'll chown
        # it to the right user later if need be
        #
        chown(0,0,$dir);

        #
        # Here we chown it to the user *unless*..
        #
        # lets not chown any special dirs to anyone other than root
        # they're system dirs, let overlays handle them
        #
        # while we're at it, we'll populate skel stuff
        #

        # We only do this for non-root users with non-system homedirs
        if (!exists($system_homedirs{$acct->{homedir}})
                && $acct->{uid} != 0) {

            chown($acct->{uid}, $acct->{gid}, $dir);

            my $skel = catfile($c->getval('c_croot'),
                               qw(includes skel default));

            if ($acct->{skeldir}) {
                $skel = catfile($c->getval('c_croot'), $acct->{skeldir});
            }
			
            _copy_skel_dir($c,$skel,catfile($tmpdir, $acct->{homedir}),
                           $acct->{uid},$acct->{gid});
        }
    }

    unless (close(PASSWD))
    {
        $c->error("couldn't close passwd",'crit');
        return PLUGIN_FATAL;
    }

    unless (close(SHADOW))
    {
        $c->error("couldn't close shadow",'crit');
        return PLUGIN_FATAL;
    }

    #
    # Sanity checking
    #
    if ($p_errors || $s_errors || $h_errors) {
        $c->error("I have a blank passwd or shadow file, can't continue",
                  'crit');
        return PLUGIN_FATAL;
    }

    # We don't check the number of homedirs processed because we nearly always
    # won't process some
    if ($p_count != $s_count) {
        $c->error("The number of passwd and shadow entries aren't identical!",
                  'crit');
        return PLUGIN_FATAL;
    }

    return 0;
}


sub _generate_group
{
    my ($c, $tmpdir) = @_;
    my (@group);

    my $group_map = $AUTH->{group_map};

    my @gid_ordered_groups = sort {
        int($group_map->{$a}->{_gid}) <=> int($group_map->{$b}->{_gid});
    } keys(%{$group_map});

    #
    # Sanity checking
    #
    unless (scalar(@gid_ordered_groups)) {
        $c->error("I have a blank group file, can't continue", 'crit');
        return PLUGIN_FATAL;
    }

    my $filename = catfile($tmpdir, qw(etc group));
    unless (open(GROUP, "> $filename"))
    {
        $c->error("couldn't open $tmpdir/etc/group",'crit');
        return PLUGIN_FATAL;
    }
    chown(0, 0, $filename);
    chmod(0444, $filename);

    #
    # Emit
    #
    my $g_errors = 0;

    foreach my $group (@gid_ordered_groups)
    {
        my @members;
        foreach my $name (keys(%{$group_map->{$group}})) {
            if ($name eq '_gid') {
                # This is the only entry in the hash that's
                # not a member.
                next;
            }
            push @members, $name;
        }

        unless (print GROUP join(':', $group, 'x', $group_map->{$group}->{_gid},
                                 join(',', @members)), "\n")
        {
            $g_errors++;
        }
    }

    unless (close(GROUP))
    {
        $c->error("couldn't close group",'crit');
        return PLUGIN_FATAL;
    }

    #
    # Sanity checking
    #
    if ($g_errors) {
        $c->error("I didn't write the proper number of group entries!",
                  'crit');
        return PLUGIN_FATAL;
    }

    return 0;
}


sub _generate_authorized_keys
{
    my ($c, $tmpdir, $min_root_keys, $accounts) = @_;

    my $local_authkeys = $c->getval_last('local_authorized_keys');
    my $user_map = $AUTH->{user_map};
    my $a_t = $AUTH->{auth_type};

    my $errors = 0;

    # FIXME  Should this be locally scoped here?  Doesn't matter a whole lot
    #        but I don't think it would be needed anywhere else.
    #
    # rtilder    Tue Dec 19 10:39:48 PST 2006
    sub _build_key_list
    {
        my ($person, $account, $keyopts, $a_t) = @_;
        my $keytype = 'key';
        my @keys;

        $keyopts =~ s/(?:\@\@user\@\@)/$person/g;
        $keyopts =~ s/(?:\@\@gecos\@\@)/$account->{gecos}/g;

        if ($keyopts) {
            $keyopts .= ' ';
        }

        if (exists($account->{'key' . $a_t})) {
            $keytype = 'key' .  $a_t;
        }

        foreach my $user_key (@{$account->{$keytype}}) {
            push(@keys, $keyopts . $user_key);
        }

        return @keys;
    }


    while (my ($user, $map) = each(%{$user_map})) {
        my $keyopts = $accounts->{$user}->{keyopts};

        my @keys;

        #
        # Make an array of what will go into their authorized
        # keys file - we do this seperately from making the file
        # for ease of sanity checking
        #
        if (defined($map)) {
            #
            # If $map is defined, its a role account, so we
            # loop through the people and add each person's key
            #

            foreach my $person (keys(%{$map})) {
                $c->print(5, "Adding \"$person\" to \"$user\" keys file");
                push @keys, _build_key_list($person,
                                            $AUTH->{accounts}->{$person},
                                            $keyopts, $a_t);
            }
        } else {
            #
            # If map is not defined, it's an individual user account so
            # we just add that key.
            #
            push @keys, _build_key_list($user,
                                        $AUTH->{accounts}->{$user},
                                        $keyopts, $a_t);
        }

        #
        # Sanity checking - we want at least some keys for root
        #
        if ($user eq 'root'
            && (scalar(@keys) < $min_root_keys)) {
            $c->error("Root's authorized_keys file is too"
                      . " small (< $min_root_keys entries), something"
                      . ' is wrong!', 'crit');
            return PLUGIN_FATAL;
        }

        # If it's empty, don't create the file
        unless (scalar(@keys)) {
            $c->cprint("Not creating authorized_keys for $user: no keys", 3);
            next;
        }

        my ($keydir,$keyfile);
        if ($local_authkeys == 1) {
            $keydir = catfile($tmpdir, $accounts->$user->{homedir}, '.ssh');
            mkdir_p($keydir);
            chown($user->{uid}, $user->{gid}, $keydir);
            $keyfile = catfile($keydir, 'authorized_keys');
        } else {
            $keydir = catfile($tmpdir, qw(etc ssh authorized_keys));
            chown(0, 0, $keydir);
            chmod(0755, $keydir);
            $keyfile = catfile($keydir, $user);
        }

        unless (open(KEYS,">$keyfile"))
        {
            $c->error("couldn't open $keyfile",'crit');
            $errors++;
            next;
        }

        $c->print(3, "Adding " . scalar(@keys) . " keys to \"$user\"'s key file");

        foreach (sort @keys) {
            $c->print(7, "Adding to \"$keyfile\": $_");
            unless (print KEYS $_, "\n") {
                $c->error("Failed to output to $keyfile: $!", 'crit');
                $errors++;
                last;
            }
        }
			
        unless (close(KEYS))
        {
            $c->error("couldn't close $keyfile",'crit');
            $errors++;
        }

        chmod(0444, $keyfile);
    }

    return $errors;
}


#
# _get_user_auth_data is a helper function to fill in the
# @users data structure and returns some user attribute
#
sub _get_user_auth_data
{
    my ($user, $field, $accounts, $auth_type) = @_;

    my $person_auth_ptr = $accounts->{$user};

    if (exists $person_auth_ptr->{$field . $auth_type}) {
        return $person_auth_ptr->{$field . $auth_type};
    }

    # If this key doesn't exist, it'll return undef.
    return $person_auth_ptr->{$field};
}


#
# A recursive directory copy and chowning things to root - fairly
# specific to skel because of that.
#
sub _copy_skel_dir
{
    my ($c, $src, $dst, $uid, $gid) = @_;

    unless ( -d $src && -d $dst ) {
        return 0;
    }

    my @entries;

    unless (opendir(DIR,$src))
    {
        $c->error("Couldn't open dir ($src)", 'crit');
        return 0;
    }

    while (defined(my $d_entry = readdir(DIR))) {
        if ($d_entry =~ m/^.{1,2}$/o) {
            next;
        }
        push @entries, $d_entry;
    }

    unless (closedir(DIR))
    {
        $c->error("Couldn't close dir ($src)", 'crit');
        return 0;
    }

    foreach my $entry (@entries) {

        if ( -d catfile($src, $entry)) {
            mkdir_p(catfile($dst,$entry),755);
            if($entry eq ".ssh") {
                chown($uid,$gid,catfile($dst,$entry));
                chmod(0700,catfile($dst,$entry));
            }
            _copy_skel_dir($c,catfile($src,$entry),catfile($dst,$entry),
                $uid,$gid);
            next;
        }

        unless (copy(catfile($src, $entry),$dst))
        {
            $c->error("Couldn't copy file $entry to "
                    . $dst, 'crit');
            return 0;
        }
        chown(0, 0, catfile($dst, $entry));
        chmod(0644, catfile($dst, $entry));
        # for private keys, chown to the, and make it restrictive
        # permissions
        if ($entry eq "id_dsa") {
            chown($uid, $gid, catfile($dst, $entry));
            chmod(0600, catfile($dst, $entry));
        }
    }
}


package Spine::Plugin::Auth::Wrapper;

use Spine::Plugin::Auth;

sub new
{
    my $foo = '';
    bless \$foo, +shift;
}


sub accounts
{
    return $Spine::Plugin::Auth::AUTH->{accounts};
}


sub auth_groups
{
    return $Spine::Plugin::Auth::AUTH->{auth_groups};
}


sub uid_map
{
    return $Spine::Plugin::Auth::AUTH->{uid_map};
}


sub gid_map
{
    return $Spine::Plugin::Auth::AUTH->{gid_map};
}


sub user_map
{
    return $Spine::Plugin::Auth::AUTH->{user_map};
}


sub group_map
{
    return $Spine::Plugin::Auth::AUTH->{group_map};
}


sub auth_type
{
    return $Spine::Plugin::Auth::AUTH->{auth_type};
}


1;
