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

package Spine::Plugin::Overlay;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin :basic :keys);
use Spine::Registry;
use IO::File;
use Digest::MD5;
use File::Find;
use Text::Diff;
use File::Spec::Functions;
use File::stat;
use Fcntl qw(:mode);
use Spine::Util qw(simple_exec do_rsync mkdir_p octal_conv uid_conv gid_conv);

our ( $VERSION, $DESCRIPTION, $MODULE, $DONTDELETE, $TMPDIR, @ENTRIES );

$VERSION = sprintf( "%d", q$Revision$ =~ /(\d+)/ );

$DESCRIPTION = "Parselet::Basic, processes Basic keys";

$MODULE = {
    author      => 'osscode@ticketmaster.com',
    description => $DESCRIPTION,
    version     => $VERSION,
    hooks       => {
        "INIT" => [ { name => 'create_overlay_store',
                      code => \&init } ],
        PREPARE => [ { name => 'build_overlay',
                       code => \&build_overlay } ],
        APPLY => [ { name => 'apply_overlay',
                     code => \&apply_overlay,
                     provides => [ 'overlay',
                                   'overlay1' ] },
                   { name => 'apply_overlay_pass_two',
                     code => \&apply_overlay_two,
                     position => HOOK_END,
                     provides => [ 'overlay', 'overlay2' ] } ],
        CLEAN => [ { name => 'clean_overlay',
                     code => \&clean_overlay } ],
        'PARSE/branch' => [ { name => 'load_overlay',
                            code => \&load_overlay ,
                            position => HOOK_START } ] },
    cmdline => { options => { 'keep-overlay' => \$DONTDELETE } } };

# FIXME: icky
my $c;
my $DRYRUN;

sub init {
    my $c = shift;
    $c->set( SPINE_OVERLAY_KEY, new Spine::Plugin::Overlay::Key() );
    return PLUGIN_SUCCESS;
}

# We hook into the PAESE/branch so that pluggins that automatically
# add overlays for each branch have a change to register them before
# user defined overlays are added.
sub load_overlay {
    my ($c, $branch) = @_;

    my $registry = new Spine::Registry;

    my $point = $registry->get_hook_point('PARSE/Overlay/load');
    my $rc = $point->run_hooks( $c, $branch );
   return PLUGIN_ERROR unless ( $rc == 0 );

   return PLUGIN_SUCCESS;
}

sub build_overlay {
    $c = shift;

    my $croot   = $c->getval('c_croot');
    my $tmpdir  = $c->getval('c_tmpdir');
    my $tmplink = $c->getval('c_tmplink');

    my $overlay_data   = $c->getkey(SPINE_OVERLAY_KEY);
    my $bound_overlays = $overlay_data->get_bound();

    my @excludes = @{ $c->getvals('build_overlay_excludes') }
      if ( $c->getval('build_overlay_excludes') );
    my $ignore_errs = $c->getval_last('ignore_errors_build_overlay');

    my $dryrun = $c->getval('c_dryrun');

    my $registry = new Spine::Registry;
    my $point    = $registry->get_hook_point('PREPARE/Overlay/build');

    my $settings = { tmpdir   => $tmpdir,
                     excludes => \@excludes,
                     croot    => $croot,
                     dryrun   => $dryrun };

    # Initial steps, should be moved to a hook near the start....
    remove_tmpdir( $c, $tmpdir );
    unless ( mkdir_p( $tmpdir, 0755 ) ) {

        # Return a fatal error to the caller.
        $c->error( "could not create temp directory", 'crit' );
        return PLUGIN_FATAL;
    }

    # Create a symlink pointing to the most recent overlay.
    unlink $tmplink if ( -l $tmplink );
    symlink $tmpdir, $tmplink;

    # loop over all the overlays that have neem bound to paths
    foreach my $overlay_item ( @{$bound_overlays} ) {

        # create settings for this overlay from the global and overlay items
        my $item_settings = { %$settings, %$overlay_item };

        # The following two gets set so that things like templates within
        # overlays know where they came from
        $c->set( "c_current_overlay", $item_settings );
        $c->print( 4,
                   "Processing the overlay (" . $item_settings->{name} . ")" );
        my ( undef, $rc, undef ) =
          $point->run_hooks_until( PLUGIN_STOP, $c, $item_settings );

        if ( $rc == PLUGIN_NOHOOKS ) {
            $c->cprint( "unable to build overlay ($overlay_item->{name})."
                          . " No plugins for PREPARE/Overlay/build",
                        2 );
            return PLUGIN_NOHOOKS;
        }

        if ( $rc == PLUGIN_FATAL ) {
            $c->error( "could not build overlay \""
                         . $overlay_item->{uri}
                         . "\" for ("
                         . $overlay_item->{path} . ".)",
                       $ignore_errs ? 'warn' : 'error' );
            return PLUGIN_FATAL unless $ignore_errs;
        }
    }
    return PLUGIN_SUCCESS;
}


sub apply_overlay {
    $c = shift;
    my $tmpdir         = $c->getval('c_tmpdir');
    my $tmplink        = $c->getval('c_tmplink');
    my $overlay_root   = $c->getval('overlay_root');
    my $excludes       = $c->getvals('apply_overlay_excludes');
    my $max_diff_lines = $c->getval('max_diff_lines_to_print');
    my %rsync_args = ( Config   => $c,
                       Source   => $tmpdir,
                       Output   => undef,
                       Target   => $overlay_root,
                       Options  => [qw(-c)],
                       Excludes => $excludes );

    $TMPDIR  = $tmpdir;
    $DRYRUN  = $c->getval('c_dryrun');
    @ENTRIES = ();

    if ( $overlay_root eq '' ) {
        $c->error( 'overlay_root key does not exist, no changes will be '
                     . 'applied!',
                   'warn' );
    }

    unless ( -d $tmpdir ) {
        $c->error( "temp directory [$tmpdir] does not exist", 'crit' );
        return PLUGIN_FATAL;
    }

    # Make sure that the source matches rsync's include pattern rules.
    unless ( $tmpdir =~ m|/$| ) {
        $rsync_args{Source} = "$tmpdir/";
    }

    # Populates @ENTRIES via the find_changed() callback
    find( { follow => 0, no_chdir => 1, wanted => \&find_changed }, $tmpdir );

    foreach my $srcfile (@ENTRIES) {
        chomp $srcfile;    # most likely redundant
        my $destfile = $srcfile;

        if ( $srcfile !~ m!^$tmpdir! ) {
            $srcfile = $tmpdir . $srcfile;
        } else {
            ( undef, $destfile ) = split( /$tmpdir/, $srcfile );
        }
        next if $destfile =~ /^$/;

        sync_attribs( $c, $srcfile, $destfile ) if ( -e $destfile );

        # Compare the source and destination files.  If nothing
        # has changed, delete the source file from the temp overlay.
        if ( ( -f $destfile ) && ( -f $srcfile ) ) {

            # if the source/dest file is binary, don't bother calculating
            # diffs, since they are likely undisplayable anyways
            if (    ( -B $destfile && !-z $destfile )
                 || ( -B $srcfile && !-z $srcfile ) )
            {
                $c->print( 2, "Patching binary file $destfile" );
                next;
            }

            my $diff = diff( $destfile, $srcfile );
            my @diff = split( /\n/, $diff );

            if ( length($diff) ) {
                $c->print( 2, "updating $destfile" );

                my $size = scalar(@diff);

                if (     defined($max_diff_lines)
                     and $max_diff_lines > 0
                     and $size >= $max_diff_lines )
                {
                    $c->print( 2,
                               "Changes to $destfile are too large to print("
                                 . "$size >= $max_diff_lines lines)" );
                } else {
                    foreach my $line (@diff) {
                        $line =~ s/$tmpdir/spine-overlay/g;
                        $c->cprint( "    $line", 2, 0 )
                          if ( $line =~ /^[+-]/ );
                    }
                }
                utime( time, time, $srcfile );
            }
        } elsif ( not -e $destfile ) {
            my $src_stat = lstat($srcfile);

            $c->print( 2,
                       "creating $destfile"
                         . ' [mode '
                         . octal_conv( $src_stat->mode ) . ' |'
                         . ' owner/group '
                         . uid_conv( $src_stat->uid ) . ':'
                         . gid_conv( $src_stat->gid ) . ']' );

            utime( time, time, $srcfile );
        }
    }

    unless ($DRYRUN) {
        if ( do_rsync(%rsync_args) != SPINE_SUCCESS ) {

            # These particular return values don't necessarily indicate that
            # the transfer wasn't at least partially successful.  See the
            # rsync man page for more information.  Necessary because /media
            # is read only almost everywhere but the mount point needs to be
            # created if the filesystem
            #
            # rtilder    Wed Jun  6 14:08:49 PDT 2007
            my $rc = $? >> 8;

            if ( $rc == 23 or $rc == 24 ) {
                $c->error( "rsync partial failure!  This is probably very bad.",
                           'err' );

                if ( $c->getval('partial_rsync_ok') ) {
                    return PLUGIN_SUCCESS;
                }
            }

            $c->error( "rsync failed!  Couldn't apply filesystem changes",
                       'err' );
            return PLUGIN_FATAL;
        }
    }

    return PLUGIN_SUCCESS;
}

sub apply_overlay_two {
    
    # no point doing a second pass during a dryrun
    return PLUGIN_SUCCESS if $_[0]->getval('c_dryrun');
    
    return apply_overlay(@_);
}

#
# @ENTRIES is a module level global
#
sub find_changed {
    my $fname = $File::Find::name;

    # The target filename
    my ( undef, $dest ) = split( /$TMPDIR/, $fname );

    if (    $fname eq $TMPDIR
         or $fname eq "$TMPDIR/" )
    {
        return;
    }

    my $lstat = lstat($fname);
    my $dstat = lstat($dest);

    # Destination doesn't exist?
    unless ( defined($dstat) ) {
        goto changed;
    }

    # rdev seems unreliable on 2.4 kernels
    my $kernel_version = $c->getval('c_current_kernel_version');
    my $rdev           = 0;
    if ( $kernel_version =~ /^2\.4\./ ) {
        $rdev = 1;
    } elsif ( $lstat->rdev == $dstat->rdev ) {
        $rdev = 1;
    }

    # Any change in the important stat data?  We disregard A, C, and M times
    # for the newly created overlay for obvious reasons
    unless (     $lstat->mode == $dstat->mode
             and $lstat->uid == $dstat->uid
             and $lstat->gid == $dstat->gid
             and $lstat->size == $dstat->size
             and $rdev )
    {
        goto changed;
    }

    # If it's a file, are the contents the same?
    elsif ( S_ISREG( $lstat->mode ) and S_ISREG( $dstat->mode ) ) {
        my $currfh = new IO::File($dest);
        my $newfh  = new IO::File($fname);
        my $curr   = new Digest::MD5();
        my $new    = new Digest::MD5();

        binmode $currfh;
        binmode $newfh;

        $curr->addfile($currfh);
        $new->addfile($newfh);

        $currfh->close();
        $newfh->close();
        undef $currfh;
        undef $newfh;

        unless ( $curr->hexdigest() eq $new->hexdigest() ) {
            goto changed;
        }

        undef $curr;
        undef $new;
    } elsif ( S_ISLNK( $lstat->mode ) and S_ISLNK( $dstat->mode ) ) {
        my $curr_target = readlink $fname;
        my $new_target  = readlink $dest;

        if ( ( defined($curr_target) and defined($new_target) )
             and $curr_target ne $new_target )
        {
            goto changed;
        }
    }

    utime $dstat->atime, $dstat->mtime, $fname;
    return;

  changed:
    push @ENTRIES, $dest;
    return;
}

sub clean_overlay {
    my $c       = shift;
    my $tmpdir  = $c->getval('c_tmpdir');
    my $tmplink = $c->getval('c_tmplink');
    my $rc      = 0;

    # If --keep-overlay was specified on the command line, pretend like we did
    if ($DONTDELETE) {
        $c->print( 1, "Leaving overlay in \"$tmpdir\"" );
        return PLUGIN_SUCCESS;
    }

    $rc = remove_tmpdir( $c, $tmpdir );
    unlink $tmplink;

    return PLUGIN_SUCCESS;
}

sub remove_tmpdir {
    my $c      = shift;
    my $tmpdir = shift;

    # rm -rf paranoia.
    # FIXME: tmp should not be assumed to be in '/'
    if ( ( $tmpdir =~ m@^/tmp/.*@ ) and ( $tmpdir =~ m@[^\.~]*@ ) ) {
        my $result = simple_exec( merge_error => 1,
                                  exec        => 'rm',
                                  inert       => 1,
                                  c           => $c,
                                  args        => "-rf $tmpdir" );
        return 1;
    }

    return 0;
}

sub sync_attribs {
    $c = shift;
    my ( $srcfile, $destfile ) = @_;

    my $src_stat  = lstat($srcfile);
    my $dest_stat = lstat($destfile);

    unless ( $src_stat->mode eq $dest_stat->mode ) {
        $c->print( 2,
                   "updating permissions on $destfile from "
                     . octal_conv( $dest_stat->mode ) . " to "
                     . octal_conv( $src_stat->mode ) );

        chmod $src_stat->mode, $destfile
          unless ($DRYRUN);
    }

    unless (     ( $src_stat->uid eq $dest_stat->uid )
             and ( $src_stat->gid eq $dest_stat->gid ) )
    {
        $c->print( 2,
                   "updating owner/group on $destfile from "
                     . uid_conv( $dest_stat->uid ) . ":"
                     . gid_conv( $dest_stat->gid ) . " to "
                     . uid_conv( $src_stat->uid ) . ":"
                     . gid_conv( $src_stat->gid ) );
    }

    chown $src_stat->uid, $src_stat->gid, $destfile
      unless ($DRYRUN);
}

1;

# The following package is a special implementation of a spine key
# just for overlays
package Spine::Plugin::Overlay::Key;
use Spine::Resource qw(resolve_resource);
use base qw(Spine::Key);

sub new {
    my $klass = shift;

    my $data = { bound        => [],
                 overlays     => {},
                 overlay_data => {} };

    my $self = Spine::Key->new($data);
    return bless( $self, $klass );
}

sub add {
    my ( $self, $resource) = @_;
    my $data = $self->get();
    $data->{overlays}->{ $resource->{name} } = $resource;
}

sub add_data {
    my ( $self, $name, $data ) = @_;

    my $item = $self->get();

    $item->{overlay_data}->{$name} = $data;

}

sub remove {
    my ( $self, $name ) = @_;

    my $data = $self->get();

    if ( exists $data->{overlays}->{$name} ) {
        delete $data->{overlays}->{$name};
    }

    if ( exists $data->{overlay_data}->{$name} ) {
        delete $data->{overlay_data}->{$name};
    }

    # remove any time this was bound
    for ( my $i = 0 ; $i < scalar( @{ $data->{bound} } ) ; $i++ ) {
        if ( $data->{bound}->[$i]->[0] eq $name ) {
            splice( @{ $data->{bound} }, $i, 1 );
        }
    }
}

sub bind {
    my ( $self, $name, $path ) = @_;

    # Deal with arrays as if it's multiple paths
    if ( ref($path) eq "ARRAY" ) {
        foreach (@$path) {
            $self->bind( $name, $_ );
        }
        return undef;
    }

    my $data = $self->get();

    return undef unless ( exists $data->{overlays}->{$name} );

    push @{ $data->{bound} }, [ $name, $path ];

    return $name;
}

# TODO
sub unbind {
    my ( $self, $name, $path ) = @_;
}

sub data_getref {
    my $self = shift;

    return \$self->get_bound(@_);
}

sub get_bound {
    my ($self) = @_;

    my $data  = $self->get();
    my $items = [];

    # return an array of arrays containgin name, path, uri
    foreach my $bound ( @{ $data->{bound} } ) {
        my $overlay_data =
          exists $data->{overlay_data}->{ $bound->[0] }
          ? $data->{overlay_data}->{ $bound->[0] }
          : "";
        push @$items,
          { name => $bound->[0],
            path => $bound->[1],
            resource  =>  $data->{overlays}->{ $bound->[0] },
            data => $overlay_data };
    }
    return $items;
}

sub set {
    return undef;
}

# override the standard merge function
sub merge {
    my ( $self, $obj ) = @_;

    if ( $self->is_related($obj) ) {
        $obj = $obj->merge_helper($obj);
    }

    # Recursive call if we have more then one item
    if ( ref($obj) eq "ARRAY" ) {
        foreach (@$obj) {
            $self->merge($_);

        }
        return undef;
    }
    
    my $resource = resolve_resource($obj);
    return undef unless ( defined $resource );

    $self->add($resource);

    # if it was just a scalar we assume it's bound to '/'
    unless ( ref($obj) ) {
        $self->bind( $resource->{name}, "/" );

    }

    # Register any data if there is any
    if ( exists $resource->{data} ) {
        $self->add_data( $resource->{name}, delete $resource->{data} );
    }
    # bind it if there are any bind options
    if ( exists $resource->{bind} ) {
        $self->bind( $resource->{name}, delete $resource->{bind} );
    }
}

# This is used to tell operators that this key should be merged by default
sub merge_default() {
    return 1;
}

1;
