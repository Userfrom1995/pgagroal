/*
 * Copyright (C) 2026 The pgagroal community
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

#include <mctf_logslice.h>

#include <pgagroal.h>
#include <shmem.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MCTF_MAX_PATH 1024

static int
mctf_get_pgagroal_log_path(char* path, size_t size)
{
   struct main_configuration* config = (struct main_configuration*)shmem;
   int n = 0;

   if (path == NULL || size == 0)
   {
      return 1;
   }

   if (config != NULL && config->common.log_path[0] != '\0')
   {
      n = snprintf(path, size, "%s", config->common.log_path);
   }
   else
   {
      n = snprintf(path, size, "/tmp/pgagroal-test/log/pgagroal.log");
   }

   if (n <= 0 || (size_t)n >= size)
   {
      return 1;
   }

   return 0;
}

static int
mctf_get_log_size(off_t* out_size)
{
   char log_path[MCTF_MAX_PATH];
   struct stat st;

   if (out_size == NULL)
   {
      return 1;
   }

   if (mctf_get_pgagroal_log_path(log_path, sizeof(log_path)) != 0)
   {
      return 1;
   }

   if (stat(log_path, &st) != 0)
   {
      return 1;
   }

   *out_size = st.st_size;
   return 0;
}

static long
mctf_monotonic_ms(void)
{
   struct timespec ts;

   if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
   {
      return 0;
   }

   return (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
}

void
mctf_capture_log_boundary(off_t* out_size)
{
   const long stable_ms = 300;
   const long timeout_ms = 5000;
   const long poll_ms = 25;
   long started_at = 0;
   long stable_since = 0;
   off_t last_size = 0;
   off_t current_size = 0;

   if (out_size == NULL)
   {
      return;
   }

   if (mctf_get_log_size(&last_size) != 0)
   {
      *out_size = -1;
      return;
   }

   started_at = mctf_monotonic_ms();
   stable_since = started_at;

   while (mctf_monotonic_ms() - started_at <= timeout_ms)
   {
      if (mctf_get_log_size(&current_size) != 0)
      {
         *out_size = -1;
         return;
      }

      if (current_size != last_size)
      {
         last_size = current_size;
         stable_since = mctf_monotonic_ms();
      }
      else if (mctf_monotonic_ms() - stable_since >= stable_ms)
      {
         *out_size = current_size;
         return;
      }

      usleep((useconds_t)(poll_ms * 1000));
   }

   *out_size = last_size;
}

void
mctf_analyze_and_write_test_log_slice(const char* module,
                                      const char* test_name,
                                      off_t start_offset,
                                      off_t end_offset,
                                      bool* out_has_error,
                                      char** out_error_summary)
{
   char log_path[MCTF_MAX_PATH];
   char slice_path[MCTF_MAX_PATH];
   char log_dir[MCTF_MAX_PATH];
   struct stat st;
   FILE* src = NULL;
   FILE* dst = NULL;
   char line[4096];
   char error_summary[1536];
   size_t error_used = 0;
   char warn_summary[1536];
   size_t warn_used = 0;
   bool has_error = false;
   char* slash = NULL;

   if (out_has_error != NULL)
   {
      *out_has_error = false;
   }
   if (out_error_summary != NULL)
   {
      *out_error_summary = NULL;
   }

   if (module == NULL || test_name == NULL || start_offset < 0)
   {
      return;
   }

   if (mctf_get_pgagroal_log_path(log_path, sizeof(log_path)) != 0)
   {
      return;
   }

   if (stat(log_path, &st) != 0)
   {
      return;
   }

   if (end_offset <= 0 || end_offset > st.st_size)
   {
      end_offset = st.st_size;
   }

   if (start_offset >= end_offset)
   {
      return;
   }

   memset(log_dir, 0, sizeof(log_dir));
   strncpy(log_dir, log_path, sizeof(log_dir) - 1);
   slash = strrchr(log_dir, '/');
   if (slash == NULL)
   {
      return;
   }
   *slash = '\0';

   if (snprintf(slice_path, sizeof(slice_path), "%s/%s__%s.pgagroal.log", log_dir, module, test_name) <= 0)
   {
      return;
   }

   src = fopen(log_path, "r");
   if (src == NULL)
   {
      return;
   }

   if (fseeko(src, start_offset, SEEK_SET) != 0)
   {
      fclose(src);
      return;
   }

   dst = fopen(slice_path, "w");
   if (dst == NULL)
   {
      fclose(src);
      return;
   }

   error_summary[0] = '\0';
   warn_summary[0] = '\0';

   while (true)
   {
      off_t pos = ftello(src);

      if (pos < 0 || pos >= end_offset)
      {
         break;
      }

      if (fgets(line, sizeof(line), src) == NULL)
      {
         break;
      }

      pos = ftello(src);
      if (pos > end_offset)
      {
         break;
      }

      fputs(line, dst);

      if (strstr(line, " ERROR") != NULL)
      {
         has_error = true;
         if (out_error_summary != NULL)
         {
            int n = snprintf(error_summary + error_used, sizeof(error_summary) - error_used, "      %s", line);
            if (n > 0 && (size_t)n < (sizeof(error_summary) - error_used))
            {
               error_used += (size_t)n;
            }
         }
      }
      else if (strstr(line, " WARN") != NULL)
      {
         if (out_error_summary != NULL)
         {
            int n = snprintf(warn_summary + warn_used, sizeof(warn_summary) - warn_used, "      %s", line);
            if (n > 0 && (size_t)n < (sizeof(warn_summary) - warn_used))
            {
               warn_used += (size_t)n;
            }
         }
      }
   }

   fclose(src);
   fclose(dst);

   if (out_has_error != NULL)
   {
      *out_has_error = has_error;
   }

   if (out_error_summary != NULL && has_error)
   {
      const char* log_errors_header = "Log errors:\n";
      const char* errors_header = "    Errors:\n";
      const char* warnings_header = "    Warnings:\n";

      size_t total = strlen(log_errors_header) + strlen(errors_header) + strlen(error_summary) + 1;
      if (warn_used > 0)
      {
         total += strlen(warnings_header) + strlen(warn_summary);
      }

      *out_error_summary = calloc(total, sizeof(char));
      if (*out_error_summary != NULL)
      {
         if (warn_used > 0)
         {
            snprintf(*out_error_summary, total, "%s%s%s%s%s",
                     log_errors_header,
                     errors_header, error_summary,
                     warnings_header, warn_summary);
         }
         else
         {
            snprintf(*out_error_summary, total, "%s%s%s",
                     log_errors_header,
                     errors_header, error_summary);
         }
      }
   }
}
