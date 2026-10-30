#!/usr/bin/env node
'use strict';

// Runs ServerProjextX's own Knex seed files (db/seeds/development/ in that
// repo, despite the directory name — this is the project's one and only
// seed set: jeweltype/achievements/factory reference data plus the
// "Team JewelChat" system user that controllers/mongooseim.js's push
// handler specifically checks for by name) against whatever MySQL endpoint
// this is pointed at. Sibling of run-gameserver-migration.js — same
// reasoning for why this exists as a committed script rather than a
// scratch one-off, and same reasoning for not reusing ServerProjextX's own
// knexfile_development.js directly (hardcoded localhost/root/qwerty
// connection, no way to point it at an SSM tunnel's host/port).
//
// shows_seed3.js does `knex('jcusers').del()` before inserting — destructive.
// Safe to run against a target where jcusers/jeweltype/achievements/factory
// are already empty; confirm row counts first if re-running this against
// anything that might already have real data.
//
// Usage:
//   GAMESERVER_DB_USER=admin GAMESERVER_DB_PASSWORD=*** \
//     node infra/scripts/run-gameserver-seed.js
//
// Env vars:
//   GAMESERVER_DB_HOST     default 127.0.0.1
//   GAMESERVER_DB_PORT     default 13306
//   GAMESERVER_DB_USER     required
//   GAMESERVER_DB_PASSWORD required
//   GAMESERVER_DB_NAME     default gameserver
//   SERVERPROJEXTX_PATH    default ../../../ServerProjextX (relative to this file,
//                          i.e. a sibling of this repo under the same parent dir)
//   SEED_DIR               default db/seeds/development (relative to
//                          SERVERPROJEXTX_PATH) — override if ServerProjextX
//                          ever grows a separate production-specific seed set

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
  seeds: {
    directory: path.join(
      serverprojextxPath,
      process.env.SEED_DIR || path.join('db', 'seeds', 'development')
    ),
  },
});

knex.seed
  .run()
  .then(([log]) => {
    if (log.length === 0) {
      console.log('No seed files found.');
    } else {
      console.log(`Ran ${log.length} seed file(s):`);
      log.forEach((name) => console.log(`  - ${name}`));
    }
    return knex.destroy();
  })
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('Seeding failed:', err);
    return knex.destroy().finally(() => process.exit(1));
  });
