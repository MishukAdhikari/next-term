#include "SQLiteConfig.h"

int nt_sqlite3_db_config_flag(sqlite3 *db, int op, int on) {
    int now = -1;
    if (sqlite3_db_config(db, op, on, &now) != SQLITE_OK) return -1;
    return now;
}
