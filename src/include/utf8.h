/*-------------------------------------------------------------------------
 *
 * utf8.h
 *      UTF-8 validation and utility functions for pgagroal
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *      src/include/utf8.h
 *
 *-------------------------------------------------------------------------
 */

#ifndef UTF8_H
#define UTF8_H

#include <stdbool.h>
#include <stddef.h>

/*
 * UTF-8 validation and utility functions.
 * These provide core UTF-8 support for pgagroal, with permissive fallbacks
 * to mirror PostgreSQL's behavior.
 */

/**
 * Counts the number of Unicode code points in a UTF-8 byte sequence.
 * @param buf The UTF-8 byte buffer.
 * @param len The length of the buffer in bytes.
 * @return The number of code points, or -1 on error.
 */
size_t pgagroal_utf8_char_length(const unsigned char *buf, size_t len);

/**
 * Validates UTF-8 password strictly - rejects invalid sequences (matching PostgreSQL's strict approach).
 * @param password The password to validate.
 * @param username The username for logging purposes (never logged with password).
 * @return A new allocated string with the password if valid, or NULL if invalid.
 */
char *pgagroal_validate_utf8_password(char* password, char* username);

#endif /* UTF8_H */