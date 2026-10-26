#ifndef NEXTTERM_SQLITE_CONFIG_H
#define NEXTTERM_SQLITE_CONFIG_H

#include <sqlite3.h>

/// sqlite3_db_config for one on/off setting (SQLITE_DBCONFIG_DEFENSIVE, SQLITE_DBCONFIG_DQS_DML, ...).
/// Swift can't call a C function with variable arguments, so the call is made here. Returns the setting as
/// it is after the call (0 or 1), or -1 when SQLite refused it.
int nt_sqlite3_db_config_flag(sqlite3 *db, int op, int on);

#endif
