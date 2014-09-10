#!/usr/bin/perl

# Program: view.pl
# Licence: GPL version 2
# Author: James Briggs
# Date: 2014 09 07
# Env: Perl 5
# Note: requires CREATE [[NO] FORCE] option

#
# Testing of views.
#

use strict;
use warnings;

use DBI;
use Getopt::Long;

$|=1;

use vars qw($opt_help $opt_Information $opt_force $opt_debug
	    $opt_verbose $opt_root_user $opt_root_password $opt_user $opt_password
	    $opt_database $opt_host $opt_silent);

   $opt_help = $opt_Information = $opt_force = $opt_debug = $opt_verbose = $opt_silent = 0;
   $opt_host = "localhost",
   $opt_root_user = "root";
   $opt_root_password = "";
   $opt_user = "view_user";
   $opt_password = "view_user";
   $opt_database = "view_test";
   $opt_force = 1;

   my $version = "1.0";
   my $opt_table="table1";
   my $opt_user2  =  $opt_user . '2';

   GetOptions("Information","help","server=s","root-user=s","root-password=s","user","password=s","database=s","force","host=s","debug","verbose","silent") || usage();

   usage() if ($opt_help || $opt_Information);

# magic constants

   use constant N_TEST_RECORDS => 3;

   use constant HAS_VIEW_GRANTS => 0;
   use constant NO_VIEW_GRANTS  => 1;

   my @cols = qw[id col1 col2 col3 col4];
   
   my $tmp_table="/tmp/mysql-view.test";
   unlink($tmp_table);

# %roles array offets

   use constant U_DBH        => 0;
   use constant U_PRIV_LEVEL => 1;
   use constant U_USER       => 2;
   use constant U_HOST       => 3;
   use constant U_PASSWORD   => 4;

# run tests with multiple user accounts from SUPER to very basic privs
   my %roles = (
#              [ U_DBH, U_PRIV_LEVEL,    U_USER,      U_HOST, U_PASSWORD ]

      root  => [ undef, HAS_VIEW_GRANTS, $opt_root_user, $opt_host, $opt_root_password ],
      power => [ undef, HAS_VIEW_GRANTS, $opt_user,      $opt_host, $opt_password ],
      crud  => [ undef, NO_VIEW_GRANTS,  $opt_user2,     $opt_host, $opt_password], # use the non-root user account again, this time with less privs
   );

   if (!$opt_force) {
      print_info();
   }

#
# setup test database
#

   my $dbh = user_connect($opt_root_user,$opt_root_password, 0, 'test'); # $opt_database may not exist yet, so connect with 'test'
   $roles{'root'}->[U_DBH] = $dbh;

   test_query('root', "drop database if exists $opt_database"); # drop database to quickly drop any tables and views
   test_query('root', "create database $opt_database");
   test_query('root', "use $opt_database");

#
# setup test table
#

   test_query('root', "create table $opt_table (id int primary key auto_increment, col1 int, col2 int, col3 int, col4 int)");

   my @c = @cols; # column names for test database
   shift @c; # remove first column (id)
   my $cols = join ',', @c; # squash array into a string

   for my $i (1..N_TEST_RECORDS) {
      test_query('root', "insert into $opt_table ($cols) values (2, 3, 4, 5)");
   }

   test_query('root', "grant select, insert, update, delete, create, drop, create view, show view on $opt_database.* to '$opt_user'\@'$opt_host' identified by '$opt_password'");
   my $dbh_power = user_connect($opt_user, $opt_password, 0);

   test_query('root', "grant select, insert, update, delete on $opt_database.* to '$opt_user2'\@'$opt_host' identified by '$opt_password'");
   my $dbh_crud = user_connect($opt_user2, $opt_password, 0);

   $roles{'power'}->[0] = $dbh_power;
   $roles{'crud'}->[0]  = $dbh_crud;

#
# test views
#

#  query array offsets

   use constant Q_QRY     => 0;
   use constant Q_HI_PRIV => 1;
   use constant Q_LO_PRIV => 2;
   use constant Q_OUTPUT  => 3;
   use constant Q_COMMENT => 4;

   my @t0 = (
#     [ query,                                   ignore_failure_hi_priv, ignore_failure_lo_priv, result, comment ]
#     [ Q_QRY,                                                Q_HI_PRIV, Q_LO_PRIV, Q_OUTPUT, Q_COMMENT ]

      [ "create view $opt_table as select * from $opt_table",         1, 1, undef, "should fail - duplicate object name" ],
      [ "create view view1 as select * from ${opt_table}2",           1, 1, undef, "should fail - no base table found" ],
      [ "create view view1 as select * from $opt_table",              0, 1, undef, "" ],
      [ "select count(*) from view1",                                 0, 1, N_TEST_RECORDS, "" ],
      [ "create definer = current_user() sql security invoker view v1 as select 1", 0, 1, undef, "" ],
      [ "drop view view1",                                            0, 1, undef, "" ],
      [ "drop view v1",                                               0, 1, undef, "" ],
   );

   test_driver('original create view commands', \%roles, \@t0);

#
# test new CREATE NO FORCE VIEW view options in 10.1.x
#

# CREATE FORCE VIEW should work the same as default (omitted)

   my @t1 = (
      [ "create no force view $opt_table as select * from $opt_table", 1, 1, undef, "should fail - duplicate object name" ],
      [ "create no force view view1 as select * from $opt_table",      0, 1, undef, "" ],
      [ "create no force view view1 as select * from $opt_table",      1, 1, undef, "should fail - duplicate object name" ],
      [ "select count(*) from view1",                                  0, 1, N_TEST_RECORDS, "" ],
      [ "drop view view1",                                             0, 1, undef, "" ],
   );

   test_driver('new CREATE NO FORCE VIEW options in 10.1.x', \%roles, \@t1);

#
# test new CREATE FORCE VIEW options in 10.1.x
#

# Similar to Oracle Enterprise, behavior of CREATE FORCE VIEW:
#
# - no base table needs exist at creation time
# - thus no table or column access rights need exist 
#
# - however, CREATE VIEW and SHOW VIEW should be enforced

   my @t2 = (
      [ "create force view $opt_table as select id, col1 from $opt_table",    1, 1, undef, "should fail - duplicate object name" ],
      [ "create force view view1 as select id, col1 from $opt_table",         0, 1, undef, "" ],
      [ "create force view view1 as select id, col1 from $opt_table",         1, 1, undef, "should fail - duplicate object name" ],
      [ "create force view view2 as select id, col1 from ${opt_table}2",      0, 1, undef, "" ],
# failed on "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `view1` AS select `*` AS `*` from `table1`" # note two AS symbols
  #   [ "select count(*) from view1",                                 0, 1, N_TEST_RECORDS, "" ],

      [ "drop view view1, view2",                                             0, 1, undef, "" ],
   );

   test_driver('new CREATE VIEW FORCE view options in 10.1.x', \%roles, \@t2);

# test views by automatically generating thousands of permutation of CREATE VIEW

   gen_permutations();

#
# Clean up
#

   unlink($tmp_table);

   test_query('root', "revoke all privileges, grant option from '$opt_user'\@'%'");
   test_query('root', "revoke all privileges, grant option from '$opt_user2'\@'%'");
   test_query('root', "drop database if exists $opt_database");

   print "end of test\n";

   exit 0;

#
# do permuted tests
#
# Todo:
#
# - derived tables
# - I_S tables
# - views of views
# - invalid syntax

sub gen_permutations {

# CREATE
#   [OR REPLACE]
#   [ALGORITHM = {UNDEFINED | MERGE | TEMPTABLE}]
#   [DEFINER = { user | CURRENT_USER }]
#   [SQL SECURITY { DEFINER | INVOKER }]
#   [[NO] FORCE]
#   VIEW view_name [(column_list)]
#   AS select_statement
#   [WITH [CASCADED | LOCAL] CHECK OPTION]

   use constant P_CREATE        => 0;
   use constant P_ALGORITHM     => 1;
   use constant P_DEFINER       => 2;
   use constant P_SQL_SECURITY  => 3;
   use constant P_FORCE         => 4;
   use constant P_WITH          => 5;

# insert a blank string to make the option skippable

   my @p = (
      [ 'create', 'create or replace'],
      [ '', 'undefined', 'merge', 'temptable' ],
      [ '', 'user', 'current_user'],
      [ '', 'definer', 'invoker' ],
      [ '', 'force', 'no force'],
      [ '', 'cascaded', 'local'],
   );

   my $permutations = 0;
   my $sql = '';
   my $quiet = 1;

   print "Trying create view permutations\n\n";
   
   for my $role (sort { $b cmp $a } keys %roles) {
       for my $create (@{$p[P_CREATE]}) {
           for my $algorithm (@{$p[P_ALGORITHM]}) {
               for my $definer (@{$p[P_DEFINER]}) {
                   for my $sql_security (@{$p[P_SQL_SECURITY]}) {
                       for my $force (@{$p[P_FORCE]}) {
                           for my $col_list (('', $cols)) {
                               for my $columns (('*', $cols)) {
                                   for my $with (@{$p[P_WITH]}) {

                                       next if ($columns eq '*' && $force eq 'force'); # ambiguous view definition

                                       $sql = $create . ' ';
                                       $sql .= "ALGORITHM = $algorithm " if $algorithm ne '';

                                       if ($definer ne '') {
                                          if ($definer eq 'user') {
                                             $sql .= "DEFINER = '$roles{$role}->[U_USER]'\@'$roles{$role}->[U_HOST]' ";
                                          }
                                          else {
                                             $sql .= "DEFINER = $definer ";
                                          }
                                       }
    
                                       $sql .= "$force " if $force ne '';
                                       $sql .= "VIEW ";
                                       $sql .= "view1 ";
                                       $sql .= "($col_list) " if $col_list ne '' and $col_list eq $columns; # if you use $col_list, the number of columns must match $columns
                                       $sql .= "AS SELECT $columns FROM $opt_table ";
                                       $sql .= "WITH $with CHECK OPTION" if $with ne '';
    
                                       print "$permutations:$role: $sql\n";
         
                                       my $will_error = 0;

                                       $will_error = 1 if
                                          ($role eq 'crud')                              # no grants
                                          || ($algorithm eq 'temptable' and $with ne '') # always an error to CHECK a TEMPTABLE
#                                         || ($definer eq 'user' and $role ne 'root')    # super priv needed for DEFINER user
                                       ;
         
                                       test_query('root', 'drop view if exists view1', 0, $quiet);
                                       test_query($role, $sql, $will_error, $quiet);
                                       test_query($role, 'select count(*) from view1', $will_error, $quiet);

                                       if (!$will_error && $roles{$role}->[U_PRIV_LEVEL] == HAS_VIEW_GRANTS) {
                                          if (db_cmp_count($roles{'root'}->[U_DBH], 'select count(*) from view1', N_TEST_RECORDS )) {
                                             die "error: wrong row count for '$sql'";
                                          }
                                       }

                                       $permutations++;
                                  }
                             }
                         }
                      }
                   }
               }
           }
       }
   }

   print "total permutations = $permutations\n";

   return 0;
}

sub test_driver {
   my ($heading, $r_roles, $r_qry) = @_;

   print $heading, "\n\n";

   for my $role (sort { $b cmp $a } keys %$r_roles) {
      test_query('root', "drop view if exists view1");

      for my $q (@$r_qry) {
         my $flag_fail = ($r_roles->{$role}->[U_PRIV_LEVEL] == HAS_VIEW_GRANTS) ? $q->[Q_HI_PRIV] : $q->[Q_LO_PRIV];
         print "$role '$q->[Q_QRY]'", ($flag_fail ? ' should fail' : ' should pass'), "\n";
         test_query($role, $q->[Q_QRY], $flag_fail, 0);

         if (defined $q->[Q_OUTPUT]) {
            my $ret = db_cmp_count($r_roles->{'root'}->[U_DBH], $q->[Q_QRY], ($flag_fail ? undef : $q->[Q_OUTPUT]));
            die if $ret;
         }
      }
   }

   print "\n\n";
}
   
sub usage {
   print <<EOF;
$0  Ver $version

This program tests that the VIEW commands works by creating a temporary
database ($opt_database) and users ($opt_user, $opt_user2).

Options:

--database (Default $opt_database)
  In which database the test tables are created.

--force
  Don''t ask any question before starting this test.

--host='host name' (Default $opt_host)
  Host name where the database server is located.

--Information
--help
  Print this help

--root-password
  Password for root-user.

--user  (Default $opt_user)
  A non-existing user on which we will test view commands

--password
  Password for non-root-user.

--verbose
  Write all queries when we are execute them.

--root-user='user name' (Default $opt_root_user)
  superuser for creating tables and grants
EOF
  exit(0);
}

sub print_info {
  my $tmp;

  print <<EOF;
This test will do view statements against the $opt_database database !
the $opt_database database and $opt_user user will be created and deleted !

EOF

  while (1) {
    print "Start test (yes/no) ? ";
    $tmp=<STDIN>; chomp($tmp); $tmp=lc($tmp);
    last if ($tmp =~ /^yes$/i);
    exit 1 if ($tmp =~ /^n/i);
    print "\n";
  }
}

sub user_connect {
  my ($user, $password, $ignore_error, $db) = @_;

  $db = $opt_database if not defined $db or $db eq '';

  print "Connecting $user\n" if ($opt_verbose);

  my $dbh =DBI->connect("DBI:mysql:$db:$opt_host",$user, $password, { PrintError => 0});
  if (!$dbh)
  {
    if ($opt_verbose || !$ignore_error)
    {
      print "error on connect: $DBI::errstr\n";
    }
    if (!$ignore_error)
    {
      die "The above should not have failed!";
    }
  }
  elsif ($ignore_error)
  {
    die "Connect succeeded when it shouldn't have !\n";
  }
  else {
    return $dbh;
  }
}

sub test_query {
  my ($role, $query, $ignore_error, $quiet) = @_;

  my ($package, $filename, $line) = caller;

  my $dbh = $roles{$role}->[U_DBH];

  if (defined $dbh && !$dbh->ping) {
     $roles{$role}->[U_DBH] = user_connect($roles{$role}->[U_USER], $roles{$role}->[U_PASSWORD], $ignore_error);
     $dbh = $roles{$role}->[U_DBH];
  }
  elsif (not defined $dbh) {
     $roles{$role}->[U_DBH] = user_connect($roles{$role}->[U_USER], $roles{$role}->[U_PASSWORD], $ignore_error);
     $dbh = $roles{$role}->[U_DBH];
  }

  if (do_query($dbh, $query, $ignore_error, $quiet)) {
    if (!defined($ignore_error))
    {
      print "error:$line: This query should not have failed: '$query', do SHOW CREATE VIEW VIEW_TEST.VIEW1 to troubleshoot.\n";
      exit 1;
    }
  }
  elsif (defined($ignore_error) && $ignore_error == 1)
  {
    print "error:$line: This query should not have succeeded: '$query'\n";
    exit 1;
  }
}

sub do_query {
  my ($my_dbh, $query, $ignore_error, $quiet) = @_;

  my ($sth, $row, $fatal_error);

  print "$query\n" if ($opt_debug || $opt_verbose);
  if (!($sth= $my_dbh->prepare($query)))
  {
    print "error in prepare: $DBI::errstr\n";
    return 1;
  }
  if (!$sth->execute)
  {
    $fatal_error= ($DBI::errstr =~ /parse error/);
    if (!$ignore_error || ($opt_verbose && $ignore_error != 3) || $fatal_error)
    {
      print "error in execute: $DBI::errstr\n";

      {
         my $cmd = "show create view $opt_database.view1";
         my $out = `mysql -h $opt_host -u root -p$opt_root_password -e '$cmd'`;
         print "$cmd: $out\n";
         print '"*** You have the SQL parser bug: AS select `*` AS `*` ***' . "\n" if $out =~ / AS SELECT .* AS /i;
      }
    }
    die if ($fatal_error);
    $sth->finish;
    return 1;
  }

  if (!$opt_silent and !$quiet) {
     my $found = 0;
    while (($row=$sth->fetchrow_arrayref)) {
      $found = 1;
      my $tab = '';

      for my $col (@$row) {
	print $tab;
	print defined($col) ? $col : "NULL";
	$tab="\t";
      }
      print "\n";
    }
    print "\n" if $found;
  }
  $sth->finish;

  return 0;
}

# Note: cmp_tmp_table is not currently used, but available for future use again

sub cmp_tmp_table {
   my ($s) = @_;

    if (not defined $s) {
       if (-e $tmp_table) {
          return 1;
       }
       else {
          return 0;
       }
   }

   $s =~ s/\n+$//g; # remove trailing blanks

   open X, "<", $tmp_table or return 2;
   local($/)='';
   my $t = <X>;
   close X;

   unlink($tmp_table) or warn "debug: cannot unlink tmp table";

   $t =~ s/\n+$//g;

   if ($s ne $t) {
      return 1;
   }

   return 0;
}

sub db_cmp_count {
   my ($dbh, $q, $s) = @_;

   my $sth = $dbh->prepare($q);

   my $ret = $sth->execute() || do {
      return 0 if not defined $s;
      return 2;
   };

   my $out = '';

   if (my (@row) = $sth->fetchrow_array()) {
       $out = $row[0];
   }

   $sth->finish;

   return 1 if $out != $s;

   return 0;
}

# The End.

