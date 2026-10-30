#!/usr/bin/env node
'use strict';

// Runs ServerProjextX's own Knex migrations (db/migrations/ in that repo)
// against whatever MySQL endpoint this is pointed at — used to create the
// gameserver DB's tables on RDS during the one-time bootstrap (see
// CLAUDE.md "Production AWS infrastructure"), and kept here (rather than
// as a scratch one-off) so the same step can be re-run if the infra is
// ever rebuilt from scratch, without needing to re-derive it.
//
// Deliberately does NOT reuse ServerProjextX's own knexfile_production.js:
// that file reads `durl` as a bare hostname with no port, which breaks when
// RDS is only reachable through a local SSM port-forward on a non-default
// port (3306 is typically already bound locally). This script takes host
// and port as separate env vars instead and loads knex straight out of
// ServerProjextX's own node_modules, so it always runs the exact migration
// set that repo currently has — no schema snapshot duplicated into this
// repo.
//
// Usage:
//   GAMESERVER_DB_USER=serverprojectx GAMESERVER_DB_PASSWORD=*** \
//     node infra/scripts/run-gameserver-migration.js
//
// Env vars:
//   GAMESERVER_DB_HOST     default 127.0.0.1
//   GAMESERVER_DB_PORT     default 13306
//   GAMESERVER_DB_USER     required
//   GAMESERVER_DB_PASSWORD required
//   GAMESERVER_DB_NAME     default gameserver
//   SERVERPROJEXTX_PATH    default ../../../ServerProjextX (relative to this file,
//                          i.e. a sibling of this repo under the same parent dir)

const path = require('path');

const serverprojextxPath = path.resolve(
  __dirname,
  process.env.SERVERPROJEXTX_PATH || '../../../ServerProjextX'
);

const user = process.env.GAMESERVER_DB_USER;
const password = process.env.GAMESERVER_DB_PASSWORD;
if (!user || !password) {
  console.error('GAMESERVER_DB_USER and GAMESERVER_DB_PASSWORD are required.');
  process.exit(1);
}

const knex = require(path.join(serverprojextxPath, 'node_modules', 'knex'))({
  client: 'mysql2',
  connection: {
    host: process.env.GAMESERVER_DB_HOST || '127.0.0.1',
    port: parseInt(process.env.GAMESERVER_DB_PORT || '13306', 10),
    user,
    password,
    database: process.env.GAMESERVER_DB_NAME || 'gameserver',
    charset: 'utf8',
  },
  migrations: {
    directory: path.join(serverprojextxPath, 'db', 'migrations'),
  },
});

knex.migrate
  .latest()
  .then(([batchNo, log]) => {
    if (log.length === 0) {
      console.log('Already up to date, no migrations run.');
    } else {
      console.log(`Batch ${batchNo} run: ${log.length} migration(s).`);
      log.forEach((name) => console.log(`  - ${name}`));
    }
    return knex.destroy();
  })
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('Migration failed:', err);
    return knex.destroy().finally(() => process.exit(1));
  });
