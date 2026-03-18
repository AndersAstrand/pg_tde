#!/usr/bin/perl

# Test: Stale TDE Key Cache After DROP+Recreate
#
# A long-running transaction keeps SMgrRelation structs (with cached TDE keys)
# alive. When a database is dropped and recreated with the same OID (reusing
# relfilenodes), the cached encryption key must be invalidated. Otherwise
# dirty buffers get encrypted with the stale key, causing "invalid page"
# errors.

use strict;
use warnings;
use File::Basename;
use Test::More;
use lib 't';
use pgtde;

PGTDE::setup_files_dir(basename($0));

unlink('/tmp/reuse_relfilenode_in_cache.per');

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf(
	'postgresql.conf', q[
full_page_writes = off
shared_buffers = 1MB
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
]);
$node->start;

PGTDE::psql($node, 'postgres', 'CREATE EXTENSION pg_tde;');
PGTDE::psql($node, 'postgres', 'CREATE EXTENSION pg_prewarm;');
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_add_global_key_provider_file('global-keyring',
		'/tmp/reuse_relfilenode_in_cache.per');");
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_create_key_using_global_key_provider('default-key',
		'global-keyring');");
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_set_default_key_using_global_key_provider('default-key',
		'global-keyring');");

# Template with encrypted table — ensures same relfilenodes after recreate.
PGTDE::psql($node, 'postgres',
	"CREATE DATABASE conflict_db_template OID = 50000;");
PGTDE::psql($node, 'conflict_db_template', 'CREATE EXTENSION pg_tde;');
PGTDE::psql($node, 'conflict_db_template',
	"CREATE TABLE large(id serial primary key, dataa text, datab text)
		USING tde_heap;");
PGTDE::psql($node, 'conflict_db_template',
	"INSERT INTO large(dataa, datab)
		SELECT g.i::text, 1 FROM generate_series(1, 4000) g(i);");
PGTDE::psql($node, 'postgres',
	"CREATE DATABASE conflict_db TEMPLATE conflict_db_template OID = 50001;");

# Large table in postgres to fill shared_buffers and force eviction.
PGTDE::psql($node, 'postgres', 'CREATE TABLE replace_sb(data text);');
PGTDE::psql($node, 'postgres',
	"INSERT INTO replace_sb(data)
		SELECT random()::text FROM generate_series(1, 15000);");

# Long-running session: holds SMgrRelation structs open across txn boundary.
my $psql_timeout =
  IPC::Run::timer($PostgreSQL::Test::Utils::timeout_default);
my %bg = (stdin => '', stdout => '', stderr => '');
$bg{run} = IPC::Run::start(
	[
		'psql', '--no-psqlrc', '--no-align',
		'--file' => '-',
		'--dbname' => $node->connstr('postgres')
	],
	'<' => \$bg{stdin},
	'>' => \$bg{stdout},
	'2>' => \$bg{stderr},
	$psql_timeout);

send_query_and_wait(\%bg, q[BEGIN;], qr/BEGIN/m);

# Dirty encrypted buffers, then evict through the long-running session
# so it caches TDE key K1 for conflict_db's relations.
PGTDE::psql($node, 'conflict_db', "UPDATE large SET datab = 1;");
cause_eviction(\%bg);

# Recreate database with same OID — new keys K2, same relfilenodes.
PGTDE::psql($node, 'postgres', "DROP DATABASE conflict_db;");
PGTDE::psql($node, 'postgres',
	"CREATE DATABASE conflict_db TEMPLATE conflict_db_template OID = 50001;");

# Dirty buffers again and evict. Without fix, the long-running session
# encrypts with stale K1 instead of K2.
PGTDE::psql($node, 'conflict_db', "UPDATE large SET datab = 2;");
cause_eviction(\%bg);

# Verify data is readable — fails without fix ("invalid page" error).
PGTDE::psql($node, 'conflict_db',
	"SELECT datab, count(*) FROM large GROUP BY 1 ORDER BY 1 LIMIT 10;");

$bg{stdin} .= "\\q\n";
$bg{run}->finish;
$node->stop;

# Compare the expected and out file
my $compare = PGTDE->compare_results();

is($compare, 0,
	"Compare Files: $PGTDE::expected_filename_with_path and $PGTDE::out_filename_with_path files."
);

done_testing();


sub cause_eviction
{
	my ($psql) = @_;
	send_query_and_wait(
		$psql,
		q[SELECT SUM(pg_prewarm(oid)) warmed_buffers FROM pg_class WHERE pg_relation_filenode(oid) != 0;],
		qr/warmed_buffers/m);
}

sub send_query_and_wait
{
	my ($psql, $query, $untl) = @_;

	$psql_timeout->reset();
	$psql_timeout->start();

	$$psql{stdin} .= $query;
	$$psql{stdin} .= "\n";

	$$psql{run}->pump_nb();
	while (1)
	{
		last if $$psql{stdout} =~ /$untl/;

		if ($psql_timeout->is_expired)
		{
			BAIL_OUT("aborting wait: program timed out\n"
				  . "stream contents: >>$$psql{stdout}<<\n"
				  . "pattern searched for: $untl\n");
			return 0;
		}
		if (not $$psql{run}->pumpable())
		{
			BAIL_OUT("aborting wait: program died\n"
				  . "stream contents: >>$$psql{stdout}<<\n"
				  . "pattern searched for: $untl\n");
			return 0;
		}
		$$psql{run}->pump();
	}

	$$psql{stdout} = '';
	return 1;
}
