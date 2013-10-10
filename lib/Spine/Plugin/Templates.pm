# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Templates.pm 289 2009-11-12 01:53:39Z cfb $

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

package Spine::Plugin::Templates;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $MARKERS, $QUICK);

$VERSION = sprintf("%d", q$Revision: 289 $ =~ /(\d+)/);
$DESCRIPTION = "Plugin for interperolating templates.";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { PREPARE => [ { name => 'quick_template',
                                      code => \&quick_template } ],
                       EMIT => [ { name => 'process_templates',
                                   code => \&process_templates } ]
                     },
            cmdline => { _prefix => 'template',
                         options => {
                                     'markers!' => \$MARKERS,
                                     'quick|quick!' => \$QUICK,
                                    }
                       }
          };


use File::Basename;
use File::Find;
use File::stat;
use Fcntl qw(:mode);
use Template;
use File::Spec::Functions;

my $TT = undef;

our (@TEMPLATES, @IGNORE, $TMPDIR);

sub process_templates
{
    my $c = shift;
    my $tmpdir = $c->getval('c_tmpdir');
    my $ignore = $c->getvals("templates_ignore");

    $TMPDIR = $tmpdir;
    @TEMPLATES = ();

    unless (-d $tmpdir)
    {
        $c->error("temp directory [$tmpdir] does not exist", 'crit');
        return PLUGIN_FATAL;
    }

    # Pre-compile our regular expressions for templates to ignore
    if (defined($ignore) and scalar(@IGNORE) == 0)
    {
        @IGNORE = map qr/$_/, @{$ignore};
    }
    undef $ignore;

    # Find our templates.  templates_ignore checking is done in find_templates
    find({ follow => 0, no_chdir => 1, wanted => \&find_templates }, $tmpdir);

    @TEMPLATES = sort @TEMPLATES;

    $c->print(4, 'Templates: ', @TEMPLATES);

    foreach my $template (@TEMPLATES)
    {
        my $status = process_template($c, $template);    
        if ($status != PLUGIN_SUCCESS)
            return PLUGIN_FATAL;
        }
    }

    return PLUGIN_SUCCESS;
}


# Note that we do a regular stat, not an lstat here because we want to permit
# following symlinks as necessary.
#
# rtilder    Thu May  3 11:09:00 PDT 2007
#
sub find_templates
{
    my $fname = $File::Find::name;
    my $fstat = stat($fname);

    my (undef, $dest) = split(/^$TMPDIR/, $fname);

    if ($dest =~ m/^$/)
    {
        return;
    }

    my (undef, undef, $suffix) = fileparse($fname, '.tt');

    # Doesn't end in .tt?  We don't care.
    unless ($suffix)
    {
        return;
    }

    # If it's a symlink but the target doesn't exist, then the stat() call
    # above will return undefined.
    if (defined($fstat) and S_ISREG($fstat->mode))
    {
        if (check_ignore($dest) == PLUGIN_SUCCESS)
        {
            unlink($fname);
        }
        else
        {
            push @TEMPLATES, $fname;
        }
    }
}


sub check_ignore
{
   my $path = shift;

   foreach my $regex (@IGNORE)
   {
	return PLUGIN_SUCCESS if ($path =~ m@$regex@);
   }

   return PLUGIN_ERROR;
}


sub process_template
{
    my ($c, $template, $output) = @_;
    # This makes Spine::Data avaliable as 'c' within templates
    # as well as allowing the user to stop template processing
    # if they decide the template is not needed (skip_template)
    my $ttdata = {c => $c,
                  skip_template => sub { die "__SKIP__TEMPLATE__\n" }};
    my $destdir;

    # Create our template processing instance
    unless (defined($TT))
    {
        # Do *NOT* under any circumstances add INTERPOLATE to the TT object
        # instantiation.  It blows up to all hell in all kinds of file formats,
        # most notably /etc/bashrc.tt
        #
        # rtilder    Thu Jan 11 12:04:08 PST 2007
        $TT = Template->new( { INCLUDE_PATH => $destdir,
                               EVAL_PERL           => 1,
                               PRE_CHOMP           => 1,
                               ABSOLUTE            => 1,
                               RECURSION           => 1,
                               RELATIVE            => 1,
                             } );
    }

    # If $output isn't a ref to a scalar then we output to a the template's
    # full path name minus the ".tt" extension.
    unless (defined($output) and ref($output) eq 'SCALAR')
    {
        # Seems like a lot of work to get the full path and filename minus the
        # '.tt' extension, but it should be 100% portable.
        $destdir = dirname($template);
        ($output, undef, undef) = fileparse($template, '.tt');
        $output = catfile($destdir, $output);
    }

    $c->cprint("processing template $template", 3);

    unless (defined($TT->process($template, $ttdata, $output)))
    {
        # If the user has decided they don't want the template
        # from within the template we unlink (skip_template)
        if ($TT->error() =~ m/__SKIP__TEMPLATE__/)
        {
            $c->cprint("Template has requested to be skipped, $template", 3);
            if (! $QUICK)
            {
                unlink($template);
            }
            return PLUGIN_SUCCESS;
        }
        
        $c->error("error processing $template", "err");
        $c->error('could not process template: ' . $TT->error(), "err");
        if (! $QUICK) 
        {
            # Remove the templat from the overlay.
            unlink($template);
        }
        # Check the error type to see if we need to abort the run.
        if ($TT->error()->type() eq 'spine_abort')
        {
            return PLUGIN_FATAL;
        }
        else
        {
            return PLUGIN_ERROR;
        }
    }

    unless (ref($output) eq 'SCALAR')
    {
        my $sb = stat($template);

	# For some strange reason TT does not apply the expected
	# permissions and ownership to the destination file.
	chmod $sb->mode, $output;
	chown $sb->uid, $sb->gid, $output;
        unlink($template);

        # if the template produced no output, and the user wants to,
        # prune out "empty" destination files

        # "empty" files are likely less than 0.25KB (although the template
        # could emit a lot of whitespace)
        if ((stat($output))[7] < 256)
        {
            if ($c->getval('prune_empty_output_files'))
            {
                # suck in file contents into a single scalar
                local $/;
                open INPUT, "<$output";
                my $contents = <INPUT>;
                close INPUT;

                # if it's anything other than whitespace, chuck it
                unless ($contents =~ m#\S#m)
                {
                    $c->cprint("pruning empty file $output", 3);
                    unlink($output);
                }
            }
        }

    }

    return PLUGIN_SUCCESS;
}


sub quick_template
{
    my $c = shift;

    unless ($QUICK) 
    {
        return PLUGIN_SUCCESS;
    }

    # Make sure we don't save state
    $::SAVE_STATE = 0;

    foreach my $template (@ARGV)
    {
        my $output;

        unless (-f $template)
        {
            print "No such file \"$template\"\n";
            next;
        }

        unless (process_template($c, $template, \$output))
        {
            $c->error("Failed to process template", 'err');
            return PLUGIN_EXIT;
        }

        my $file_short = basename($template);
        print "[ Start: $file_short ]\n" if ($MARKERS);
        print $output;
        print "[ End: $file_short ]\n" if ($MARKERS);
    }

    return PLUGIN_EXIT;
}


1;
