<?php
/**
 * Give Nextcloud its own least-privilege PostgreSQL role and database.
 *
 * Railway's managed Postgres only hands out the `postgres` superuser, and wiring
 * that straight into an app means any code-execution bug reaches every database on
 * the instance. A template cannot ask its user to run `CREATE ROLE` by hand — a
 * template deploy has no manual steps — so the container does it itself, once per
 * boot, idempotently, from the superuser URL the template wires up as
 * `${{Postgres.DATABASE_URL}}`.
 *
 * Nextcloud needs no untrusted PostgreSQL extension, so a plain
 * NOSUPERUSER/NOCREATEDB/NOCREATEROLE owner is sufficient.
 *
 * Runs before the Nextcloud entrypoint. Skips entirely unless
 * NEXTCLOUD_DB_BOOTSTRAP_URL is set, so an operator who would rather point
 * POSTGRES_* at a database they manage themselves simply leaves it unset.
 */

function out(string $msg): void {
    fwrite(STDERR, "bootstrap-db: $msg\n");
}

$adminUrl = getenv('NEXTCLOUD_DB_BOOTSTRAP_URL');
if ($adminUrl === false || trim($adminUrl) === '') {
    out('NEXTCLOUD_DB_BOOTSTRAP_URL is unset, leaving POSTGRES_* as supplied');
    exit(0);
}

$role     = getenv('POSTGRES_USER') ?: 'nextcloud';
$dbName   = getenv('POSTGRES_DB') ?: 'nextcloud';
$password = getenv('POSTGRES_PASSWORD') ?: '';

if ($password === '') {
    out('POSTGRES_PASSWORD is empty; refusing to create a passwordless role');
    exit(1);
}

$u = parse_url(trim($adminUrl));
if ($u === false || !isset($u['host'], $u['user'])) {
    out('NEXTCLOUD_DB_BOOTSTRAP_URL is not a valid postgres:// URL');
    exit(1);
}
$adminDb = isset($u['path']) ? ltrim($u['path'], '/') : 'postgres';
$dsn = sprintf(
    'pgsql:host=%s;port=%d;dbname=%s;connect_timeout=5',
    $u['host'],
    $u['port'] ?? 5432,
    $adminDb !== '' ? $adminDb : 'postgres'
);

// Railway has no service dependency ordering, so the database may still be booting.
$pdo = null;
for ($try = 1; $try <= 30; $try++) {
    try {
        $pdo = new PDO($dsn, rawurldecode($u['user']), rawurldecode($u['pass'] ?? ''), [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_TIMEOUT => 5,
        ]);
        break;
    } catch (PDOException $e) {
        out("waiting for postgres (attempt $try): " . $e->getMessage());
        sleep(3);
    }
}
if ($pdo === null) {
    out('could not reach postgres to bootstrap the role');
    exit(1);
}

// Identifiers are interpolated, so constrain them to something that cannot quote-escape.
foreach (['role' => $role, 'database' => $dbName] as $what => $ident) {
    if (!preg_match('/^[a-z_][a-z0-9_]{0,62}$/', $ident)) {
        out("refusing unsafe $what name: $ident");
        exit(1);
    }
}
$quotedPassword = $pdo->quote($password);

$exists = $pdo->prepare('SELECT 1 FROM pg_roles WHERE rolname = ?');
$exists->execute([$role]);
if ($exists->fetchColumn()) {
    // Keep the stored password in step with the Railway variable, so rotating it works.
    $pdo->exec("ALTER ROLE \"$role\" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD $quotedPassword");
    out("role $role already existed, password synchronised");
} else {
    $pdo->exec("CREATE ROLE \"$role\" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD $quotedPassword");
    out("created role $role");
}

$exists = $pdo->prepare('SELECT 1 FROM pg_database WHERE datname = ?');
$exists->execute([$dbName]);
if ($exists->fetchColumn()) {
    out("database $dbName already existed");
} else {
    // CREATE DATABASE cannot run inside a transaction block; PDO is autocommit here.
    $pdo->exec("CREATE DATABASE \"$dbName\" OWNER \"$role\" ENCODING 'UTF8'");
    out("created database $dbName owned by $role");
}

// Nothing else on this instance should be readable by, or reachable from, the app.
// Hardening only — the role and database above are what the install actually needs,
// so a failure here is reported and does not stop the boot.
foreach ([
    "REVOKE ALL ON DATABASE \"$dbName\" FROM PUBLIC",
    "GRANT ALL PRIVILEGES ON DATABASE \"$dbName\" TO \"$role\"",
    "REVOKE CONNECT ON DATABASE \"$adminDb\" FROM PUBLIC",
] as $sql) {
    try {
        $pdo->exec($sql);
    } catch (PDOException $e) {
        out('non-fatal: ' . $e->getMessage());
    }
}

out('done');
