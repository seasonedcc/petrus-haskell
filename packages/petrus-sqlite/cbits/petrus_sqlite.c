/* Binding text parameters straight from a Haskell Text's UTF-8 array.
 *
 * Petrus.Sqlite.Connection passes the array of a Text (an unpinned
 * ByteArray#, which the garbage collector cannot move during an unsafe
 * foreign call) with the Text's offset and length. SQLite copies the bytes
 * before returning (SQLITE_TRANSIENT, as CPython's sqlite3 binds str), so
 * nothing refers to the array afterwards. This saves the pinned UTF-8 copy
 * direct-sqlite's bindText makes of every text parameter. The caller has
 * already refused a text longer than INT_MAX bytes (bindLength, CPython's
 * OverflowError), so the length is the text's own.
 *
 * The prototype is declared here rather than included: direct-sqlite links
 * its bundled SQLite into every program that uses this package. */

#include <stddef.h>

typedef struct sqlite3_stmt sqlite3_stmt;
extern int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int, void (*)(void *));

#define PETRUS_SQLITE_TRANSIENT ((void (*)(void *)) - 1)

int petrus_sqlite_bind_text(sqlite3_stmt *statement, int index, const char *array, ptrdiff_t offset, int length)
{
    return sqlite3_bind_text(statement, index, array + offset, length, PETRUS_SQLITE_TRANSIENT);
}
