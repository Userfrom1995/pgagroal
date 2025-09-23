/*
 * Copyright (C) 2025 The pgagroal community
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this list
 * of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice, this
 * list of conditions and the following disclaimer in the documentation and/or other
 * materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors may
 * be used to endorse or promote products derived from this software without specific
 * prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
 * OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/* pgagroal */
#include <pgagroal.h>
#include <logging.h>
#include <utf8.h>

/* PostgreSQL UTF-8 support */
#include "pg_wchar.h"
#include "saslprep.h"
#include "pg_string.h"

/* system */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Only include functions that are actually used in the codebase */

/**
 * Counts the number of Unicode code points in a UTF-8 byte sequence.
 */
size_t
pgagroal_utf8_char_length(const unsigned char *buf, size_t len)
{
   size_t count = 0;
   size_t i = 0;

   // Count characters using PostgreSQL's pg_utf_mblen function and validate each character
   while (i < len)
   {
      int char_len = pg_utf_mblen(buf + i);
      if (char_len <= 0 || i + char_len > len || !pg_utf8_islegal(buf + i, char_len))
      {
         return (size_t)-1; // Invalid character
      }
      i += char_len;
      count++;
   }
   
   return count;
}

/**
 * Validates UTF-8 password strictly - rejects invalid sequences (matching PostgreSQL's approach).
 * No sanitization - invalid UTF-8 is rejected completely.
 * 
 * @param password The password to validate
 * @param username The username for logging purposes (never logged with password)
 * @return A new allocated string with the password if valid, or NULL if invalid
 */
char*
pgagroal_validate_utf8_password(char* password, char* username)
{
   if (!password)
   {
      return NULL;
   }
   
   // Fast path for ASCII using PostgreSQL's function
   if (pg_is_ascii(password))
   {
      pgagroal_log_trace("Password for user '%s' is ASCII", username);
      return strdup(password);
   }
   
   // Non-ASCII password - use PostgreSQL's strict UTF-8 validation
   size_t len = strlen(password);
   const unsigned char* p = (const unsigned char*)password;
   size_t remaining = len;
   
   // Validate each UTF-8 character - REJECT invalid sequences
   while (remaining > 0)
   {
      int char_len = pg_utf_mblen(p);
      if (char_len <= 0 || remaining < (size_t)char_len || !pg_utf8_islegal(p, char_len))
      {
         // Invalid UTF-8 - reject completely (PostgreSQL's strict approach)
         pgagroal_log_error("Invalid UTF-8 in password for user '%s' - rejecting", username);
         return NULL;
      }
      p += char_len;
      remaining -= char_len;
   }
   
   // Valid UTF-8 password
   pgagroal_log_trace("Password for user '%s' is valid UTF-8", username);
   return strdup(password);
}