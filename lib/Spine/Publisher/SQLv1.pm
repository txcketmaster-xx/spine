# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: SQL.pm,v 1.1.2.3 2007/09/13 16:15:16 rtilder Exp $

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

package Spine::Publisher::SQLv1;

use strict;

use base qw(Spine::Publisher::SQL);
use Spine::Constants qw(:publish :mime);

use DBI;
use DBI qw(:sql_types);
use File::Spec::Functions;
use IO::Scalar;

our $DEBUG = $ENV{SPINE_PUBLISHER_DEBUG} || 0;
our ($SCHEMA_STYLE, $SCHEMA_VERSION) = ('rbx', '1');
our $VERSION = sprintf("%d", q$Revision: 1 $ =~ /(\d+)/);

our @SCHEMA = (
"CREATE TABLE version_and_style (
        version                 INTEGER NOT NULL,
        style                   TEXT NOT NULL,
        UNIQUE(version, style)
);",

"INSERT INTO version_and_style (version, style) VALUES ($SCHEMA_VERSION, $SCHEMA_STYLE);",

"CREATE TABLE types (
        id                      INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        mime_type               TEXT NOT NULL,
        UNIQUE(mime_type)
);",

"CREATE TABLE overlay_targets (
        id                      INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        src                     TEXT NOT NULL,
        dest                    TEXT,
        UNIQUE(src, dest)
);",

"-- Prevent duplicate entries from being inserted
CREATE TRIGGER 'no_duplicate_overlay_targets' BEFORE INSERT ON overlay_targets FOR EACH ROW
BEGIN
        SELECT CASE WHEN ((SELECT id FROM overlay_targets
                           WHERE src = NEW.src
                           AND dest = NEW.dest) IS NOT NULL)
                THEN RAISE(IGNORE)
        END;
END;",

"-- We treat directories all special like.  Primarily because they're the
-- majority of the contents of the overlay directories
CREATE TABLE overlay_dirs (
        id                      INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        target_id               INTEGER NOT NULL,
        path                    TEXT NOT NULL,
        uid                     INTEGER NOT NULL,
        gid                     INTEGER NOT NULL,
        perms                   INTEGER NOT NULL,
        FOREIGN KEY (target_id) REFERENCES overlay_targets (id),
        UNIQUE(target_id, path, uid, gid, perms)
);",

"CREATE INDEX overlay_dirs_target_id_idx ON overlay_dirs (target_id);",

"-- Prevent duplicate entries from being inserted
CREATE TRIGGER 'no_duplicate_overlay_dirs' BEFORE INSERT ON overlay_dirs
BEGIN
        SELECT CASE WHEN ((SELECT id FROM overlay_dirs
                           WHERE target_id = NEW.target_id
                           AND path = NEW.path
                           AND uid = NEW.uid
                           AND gid = NEW.gid
                           AND perms = NEW.perms) IS NOT NULL)
                THEN RAISE(IGNORE)
        END;
END;",

"CREATE TABLE overlay_dir_config_group_mapping (
        c_g_id                  INTEGER NOT NULL,
        o_d_id                  INTEGER NOT NULL,
        FOREIGN KEY (c_g_id)    REFERENCES config_groups (id),
        FOREIGN KEY (o_d_id)    REFERENCES overlay_directory (id),
        UNIQUE(c_g_id, o_d_id)
);",

"CREATE INDEX o_d_c_g_m_group_idx ON overlay_dir_config_group_mapping (c_g_id);",

"CREATE INDEX o_d_c_g_m_dir_idx ON overlay_dir_config_group_mapping (o_d_id);",

"CREATE TABLE overlay_files (
        id                      INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        type_id                 INTEGER NOT NULL,
        target_id               INTEGER NOT NULL,
        group_id                INTEGER NOT NULL,
        path                    TEXT NOT NULL,
        uid                     INTEGER NOT NULL,
        gid                     INTEGER NOT NULL,
        perms                   INTEGER NOT NULL,
        size                    INTEGER DEFAULT 0,
        mtime                   INTEGER NOT NULL,
        atime                   INTEGER DEFAULT NULL,
        -- Not NULL for character, block, or FIFOs
        devmaj                  INTEGER DEFAULT NULL,
        devmin                  INTEGER DEFAULT NULL,
        -- The contents if it's a file.  If it's a symlink, its target.
        -- Otherwise, NULL.
        content                 BLOB DEFAULT NULL,
        FOREIGN KEY (type_id)   REFERENCES overlay_types (id),
        FOREIGN KEY (target_id) REFERENCES overlay_targets (id),
        FOREIGN KEY (group_id)  REFERENCES config_groups (id),
        UNIQUE(type_id, target_id, group_id, path)
);",

"CREATE index overlay_files_group_idx ON overlay_files (group_id);",

"-- And now our data
CREATE TABLE config_keys (
        id                      INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        group_id                INTEGER NOT NULL,
        keyname                 TEXT NOT NULL,
        content                 BLOB,
        FOREIGN KEY (group_id)  REFERENCES config_groups (id),
        UNIQUE(group_id, keyname, content)
);",

"CREATE INDEX data_group_idx ON config_keys (group_id);"
);


sub new
{
    my $proto = shift;
    my $klass = ref($proto) || $proto;
    my %args = @_;

    my $self = $klass->SUPER::new(%args);

    bless $self, $klass;

    $self->{sql} = new IO::Scalar();

    return $self;
}


sub generate
{
    my $self = shift;

    my $ballname = catfile($self->{top}, "spine-config-$self->{revision}.db");

    # Clean up the little bugger
    $self->SUPER::generate();

    # Open our DB file
    my $dbh = DBI->connect("dbi:SQLite:$ballname");

    #$DEBUG = 1;
    #$| = 1;

    $self->create_schema();

    $self->populate_types();

    # Now walk the list of config groups, populating the DB as we go
    my $cgh = $self->{dbh}->prepare("INSERT INTO config_groups (name) VALUES (?)");
    my $ckh = $self->{dbh}->prepare('INSERT INTO config_keys (group_id, keyname, '
                           . 'content) VALUES (?, ?, ?)');
    my $odh = $self->{dbh}->prepare('INSERT INTO overlay_dirs (target_id, '
                            . 'path, uid, gid, perms) VALUES (?, ?, ?, ?, ?)');
    my $ofh = $self->{dbh}->prepare('INSERT INTO overlay_files (group_id, target_id, '
                            . 'type_id, path, uid, gid, perms, size, mtime, '
                            . 'atime, devmaj, devmin, content) VALUES (?, ?, '
                            . '?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
    my $fcgh = $self->{dbh}->prepare('SELECT id FROM config_groups WHERE name = ?');
    my $fodh = $self->{dbh}->prepare('SELECT id FROM overlay_dirs WHERE '
                             . 'target_id = ? AND path = ? AND uid = ?'
                             . 'AND gid = ? AND perms = ?');
    my $map = $self->{dbh}->prepare('INSERT INTO overlay_dir_config_group_mapping '
                            . '(c_g_id, o_d_id) VALUES (?, ?)');
    #my $foth = $self->{dbh}->prepare('SELECT id FROM overlay_targets WHERE src = ? '
    #                         . 'AND dest = ?');

    # We transact an entire config group at once
    while (my ($cg_name, $cg) = each(%{$self->{config_groups}})) {
        $self->{dbh}->begin_work;

        # Create our config group
        $cgh->bind_param(1, $self->{dbh}->quote($cg_name));
        unless ($cgh->execute()) {
            die ("Failed to insert config group($cg_name): " . $cgh->errstr);
        }

        $cgh->finish();

        # Now get our group id
        $fcgh->bind_param(1, $self->{dbh}->quote($cg_name));
        unless ($fcgh->execute()) {
            die ("Failed to fetch newly created config group ID($cg_name): "
                 . $fcgh->errstr);
        }
        # $sth->bind_col() doesn't seem to work with the DBD::SQLite driver
        my $h = $fcgh->fetchrow_hashref();
        my $cg_id = $h->{id};
        undef $h;

        $fcgh->finish();

        $DEBUG && print STDOUT "Created \"$cg_name\", index \"$cg_id\".\n";

        # Walk the list of entries and populate the appropriate table
        foreach my $entry (@{$cg}) {
            if ($entry->{ct} eq SPINE_TYPE_KEY) {
                $DEBUG && print STDOUT "\tkey:  \"$entry->{n}\"\n";
                foreach my $params (( [1, $cg_id],
                                      [2, $self->{dbh}->quote($entry->{n})],
                                      [3, $entry->{c}, SQL_BLOB] )) {
                    unless ($ckh->bind_param(@{$params})) {
                        die ('Failed to bind parameters #' . $params->[0]
                             . "for key \"$entry->{n}\", group \"$cg_name\"");
                    }
                }

                unless($ckh->execute()) {
                    die ("Failed to insert key \"$entry->{n}\" in group \""
                         . $cg_name . '": ' . $ckh->errstr);
                }

                $ckh->finish();
            }
            elsif ($entry->{ct} eq SPINE_TYPE_DIR) {
                $DEBUG && print STDOUT "\tdir:  \"$entry->{n}\"\n";
                my @values = ( [1, $entry->{ot}],
                               [2, $self->{dbh}->quote($entry->{n})],
                               [3, $entry->{u}],
                               [4, $entry->{g}],
                               [5, $entry->{p}] );

                foreach my $params (@values) {
                    unless ($odh->bind_param(@{$params})) {
                        die ('Failed to bind parameters #' . $params->[0]
                             . "for dir \"$entry->{n}\", group \"$cg_name\"");
                    }
                }

                unless($odh->execute()) {
                    die ("Failed to insert key \"$entry->{n}\" in group \""
                         . $cg_name . '": ' . $odh->errstr);
                }

                $odh->finish();

                # Now populate the many-to-many mapping table
                foreach my $params (@values) {
                    unless ($fodh->bind_param(@{$params})) {
                        die ('Failed to bind parameters #' . $params->[0]
                             . "for dir \"$entry->{n}\", group \"$cg_name\"");
                    }
                }

                unless ($fodh->execute()) {
                    die ("Failed to select dir \"$entry->{n}\" in group \""
                         . $cg_name . '": ' . $fodh->errstr);
                }

                my $h = $fodh->fetchrow_hashref();

                foreach my $params (( [1, $cg_id], [2, $h->{id}] )) {
                    unless ($map->bind_param(@{$params})) {
                        die ('Failed to bind parameters #' . $params->[0]
                             . "for dir \"$entry->{n}\", group \"$cg_name\""
                             . ": mapping setup");
                    }
                }

                unless ($map->execute()) {
                    die ("Failed to map dir \"$entry->{n}\" in group \""
                         . $cg_name . '": ' . $map->errstr);
                }

                $fodh->finish();
                $map->finish();
            }
            else {
                $DEBUG && print STDOUT "\tfile: \"$entry->{n}\"\n";
                foreach my $params (( [ 1, $cg_id],
                                      [ 2, $entry->{ot}],
                                      [ 3, $entry->{ct}],
                                      [ 4, $self->{dbh}->quote($entry->{n})],
                                      [ 5, $entry->{u}],
                                      [ 6, $entry->{g}],
                                      [ 7, $entry->{p}],
                                      [ 8, $entry->{s}],
                                      [ 9, $entry->{m}],
                                      [10, exists($entry->{a}) ? $entry->{a}
                                                               : $entry->{m}],
                                      [11, exists($entry->{mj}) ? $entry->{mj}
                                                                : 'NULL'],
                                      [12, exists($entry->{mn}) ? $entry->{mn}
                                                                : 'NULL'],
                                      [13, $self->{dbh}->quote($entry->{c}), SQL_BLOB]
                                    )) {
                    unless ($ofh->bind_param(@{$params})) {
                        die ('Failed to bind parameters #' . $params->[0]
                             . "for key \"$entry->{n}\", group \"$cg_name\"");
                    }
                }

                unless($ofh->execute()) {
                    die ("Failed to insert key \"$entry->{n}\" in group \""
                         . $cg_name . '": ' . $ofh->errstr);
                }

                $ofh->finish();
            }
        }
        $self->{dbh}->commit;
    }

    $self->{dbh}->disconnect();

    $self->{filename} = $ballname;
    return $self->{filename};
}


#
# Uses the class variable @SCHEMA and the $TYPE_MAP defined in and exported by
# Spine::Constants
#
sub create_schema
{
    my $self = shift;

    # Create our schema
    $self->{dbh}->begin_work;
    foreach my $statement (@SCHEMA) {
        unless (defined($self->{dbh}->do($statement))) {
            die ("Failed to generate schema(\"$statement\"): \""
                 . $self->{dbh}->errstr . '"');
        }
    }
    $self->{dbh}->commit;

    # Populate our type table
    $self->{dbh}->begin_work;
    my $sth = $self->{dbh}->prepare("INSERT INTO types (mime_type) VALUES (?)");
    for (1 .. scalar(@{$TYPE_MAP}) - 1) {
        $sth->bind_param(1, $self->{dbh}->quote($TYPE_MAP->[$_]));
        unless ($sth->execute()) {
            die ('Failed MIME type insertion for "' . $TYPE_MAP->[$_] . '": '
                 . $sth->errstr);
        }
    }
    $self->{dbh}->commit;

    return 1;
}


# FIXME   Need to make this significantly smarter and more flexible
sub populate_types
{
    my $self = shift;

    # Populate our overlay source/target pairs in overlay_targets
    $self->{dbh}->begin_work;
    my $sth = $self->{dbh}->prepare('INSERT INTO overlay_targets (src, dest) '
                                    . 'VALUES (?, ?)');

    foreach my $o (( [qw(overlay /)], [qw(class_overlay /\$c_class)] )) {
        $sth->bind_param(1, $o->[0]);
        $sth->bind_param(2, $self->{dbh}->quote($o->[1]));
        unless ($sth->execute()) {
            die ('Failed overlay target insertion for "' . $o->[1] . '": '
                 . $sth->errstr);
        }

        # FIXME  Populate a quickie lookup table
    }
    $self->{dbh}->commit;

    # Make certain we de-allocate anything we had going on
    $sth->finish();
    undef $sth;

    return 1;
}


sub populate_items
{
    my $self = shift;

    my $fah = $self->{dbh}->prepare('SELECT id FROM attributes WHERE name = ? '
                                    . 'AND value = ?');

    foreach my $item (@_) {
        # Our content-type doesn't get stored as an attribute
        my $type_id = delete $item->{ct};

        # Make sure we populate all of our attribute entries in the table
        my %attr_ids = $self->insert_attr(%{$item});

        # Create our item
        my $id = $self->insert_item($type_id);

        $self->map_attrs_to_item(values(%attr_id));

        }
    }
}


my $IIH = undef;
my $FIH = undef;
sub insert_item
{
    my $self = shift;
    my @ids;

    unless (defined($IIH) and defined($FIH)) {
        $IIH = $self->{dbh}->prepare('INSERT INTO items (type_id) VALUES (?)');
        # Returns the highest indexed item(a.k.a our most recently inserted 
        # item
        $FIH = $self->{dbh}->prepare('SELECT id FROM items ORDER BY id DESC '
                                     . 'LIMIT 1');
    }

    if (scalar(@_) == 1 and ref($_[0]) eq 'HASH') {
        @_ = %{@_};
    }

    foreach my $type_id (@_) {
        $IIH->bind_param(1, $type_id);

        unless ($IIH->execute()) {
            die ('insert_item(): failed to INSERT: ' . $IIH->errstr);
        }

        unless ($FIH->execute()) {
            die ('insert_item(): failed to SELECT: ' . $FIH->errstr);
        }

        push @ids, $FIH->fetchrow()->[0];
    }

    return wantarray ? @ids : $ids[0];
}


my $IAH = undef;
my $FAH = undef;
sub insert_attr
{
    my $self = shift;

    my %ids;

    unless (defined($IAH) and defined($FAH)) {
        $IAH = $self->{dbh}->prepare('INSERT INTO attributes (name, value) '
                                     . 'VALUES (?, ?)');
        $FAH = $self->{dbh}->prepare('SELECT id FROM attributes WHERE '
                                      . 'name = ? AND value = ?');
    }

    if (scalar(@_) == 1 and ref($_[0]) eq 'HASH') {
        @_ = %{@_};
    }

    while (@_) {
        my $n = shift;
        my $v = shift;

        $IAH->bind_param(1, $self->{dbh}->quote($n));
        $IAH->bind_param(1, $self->{dbh}->quote($v), SQL_BLOB);

        unless ($IAH->execute()) {
            die ("insert_attr(): failed to execute INSERT: $@");
        }

        $FAH->bind_param(1, $self->{dbh}->quote($n));
        $FAH->bind_param(1, $self->{dbh}->quote($v), SQL_BLOB);

        unless ($FAH->execute()) {
            die ("insert_attr(): failed to execute SELECT: $@");
        }

        $ids{$n} = $FAH->fetchrow()->[0];
    }

    return wantarray ? %ids : \%ids;
}


my $IIAH = undef;
sub map_attrs_to_item
{
    my $self = shift;
    my $item_id = shift;

    unless (defined($IIAH)) {
        $IIAH = $self->{dbh}->prepare('INSERT INTO item_attr_map (item_id, '
                                      . 'attr_id) VALUES (?, ?)');
    }

    $IIAH->bind_param(1, $item_id);

    foreach my $attr_id (@_) {
        $IIAH->bind_param(2, $attr_id);

        unless ($IIAH->execute()) {
            die ('map_attrs_to_item(): failed to INSERT: ' . $IIAH->errstr);
        }
    }

    return 1;
}


# FIXME  Should this just do the insertion anyway since we're triggering to
#        prevent duplicates?
my $FAH = undef;
sub fetch_attr_id
{
    my $self = shift;
    my %returns;

    unless (defined($FAH)) {
        $FAH = $self->{dbh}->prepare('SELECT id FROM attributes WHERE name = ?'
                                     . ' AND value = ?');
    }

    if (scalar(@_) == 1 and ref($_[0]) eq 'HASH') {
        @_ = %{@_};
    }

    while (@_) {
        my $n = shift;
        my $v = shift;

        $FAH->bind_param(1, $self->{dbh}->quote($n));
        $FAH->bind_param(2, $self->{dbh}->quote($v));

        unless ($FAH->execute()) {
            die ("fetch_attr_id() failed to execute: $@");
        }

        $returns{$n}, $FAH->fetchrow_arrayref()->[0];
    }

    return wantarray ? %returns : \%returns;
}


my $FIH = undef;
sub fetch_item_id
{
    my $self = shift;

    unless (defined($FIH)) {
        $FIH = $self->{dbh}->prepare('SELECT item_id FROM item_attr_map WHERE '
                                     '');
    }

    foreach my $item (@_) {
        unless (ref($item) eq 'HASH') {
            die ("fetch_item(): wtf did you pass in, man!?  " . ref($item));
        }

        my %props = $self->fetch_attr_id();
    }
}


my $FABIH = undef;
sub fetch_attr_by_item_id
{
    my $self = shift;
    my $item_id = shift;
    my %attrs;

    unless (defined($FABIH)) {
        $FABIH = $self->{dbh}->prepare('SELECT name, value FROM '
                                       . 'attributes WHERE id IN  '
                                       . '(SELECT attr_id FROM item_attr_map '
                                       . ' WHERE item_id = ?)');
    }

    
}


sub clean
{
    my $self = shift;

    return 1;
}


1;
