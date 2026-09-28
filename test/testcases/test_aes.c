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
#if defined(__linux__)
#define _XOPEN_SOURCE 700
#define _GNU_SOURCE
#endif

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <ftw.h>
#include <sys/stat.h>

#include <errno.h>
#include <pgagroal.h>
#include <aes.h>
#include <mctf.h>
#include <utils.h>
#include <security.h>

static unsigned char mock_salt[PBKDF2_SALT_LENGTH];
static char original_home[MAX_PATH];
static bool original_home_set = false;
static char temp_home[MAX_PATH];

static int
unlink_cb(const char* fpath, const struct stat* sb, int typeflag, struct FTW* ftwbuf)
{
   int rv = remove(fpath);

   (void)sb;
   (void)typeflag;
   (void)ftwbuf;

   if (rv)
   {
      perror(fpath);
   }

   return rv;
}

static int
rm_rf(const char* path)
{
   return nftw(path, unlink_cb, 64, FTW_DEPTH | FTW_PHYS);
}

static int
setup_mock_master_key(void)
{
   char path[MAX_PATH];
   char dir[MAX_PATH];
   char template[] = "/tmp/pgagroal_test.XXXXXX";

   memset(mock_salt, 0xAA, sizeof(mock_salt));
   pgagroal_set_master_salt(mock_salt);

   original_home_set = false;
   if (getenv("HOME") != NULL)
   {
      pgagroal_snprintf(original_home, sizeof(original_home), "%s", getenv("HOME"));
      original_home_set = true;
   }

   if (mkdtemp(template) == NULL)
   {
      fprintf(stderr, "setup_mock_master_key: mkdtemp failed: %s\n", strerror(errno));
      return 1;
   }

   pgagroal_snprintf(temp_home, sizeof(temp_home), "%s", template);
   if (setenv("HOME", temp_home, 1) != 0)
   {
      fprintf(stderr, "setup_mock_master_key: setenv HOME failed: %s\n", strerror(errno));
      return 1;
   }

   pgagroal_snprintf(dir, sizeof(dir), "%s/.pgagroal", temp_home);
   if (mkdir(dir, S_IRWXU) != 0)
   {
      fprintf(stderr, "setup_mock_master_key: mkdir failed: %s\n", strerror(errno));
      return 1;
   }
   chmod(dir, 0700);

   pgagroal_snprintf(path, sizeof(path), "%s/.pgagroal/master.key", temp_home);
   FILE* f = fopen(path, "w");
   if (f == NULL)
   {
      fprintf(stderr, "setup_mock_master_key: fopen failed: %s\n", strerror(errno));
      return 1;
   }

   char* enc_key = NULL;
   size_t len1 = 0;
   char* enc_salt = NULL;
   size_t len2 = 0;
   if (pgagroal_base64_encode("mock-master-key-str", strlen("mock-master-key-str"), &enc_key, &len1) != 0)
   {
      fclose(f);
      fprintf(stderr, "setup_mock_master_key: base64 encode key failed\n");
      return 1;
   }
   if (pgagroal_base64_encode((char*)mock_salt, PBKDF2_SALT_LENGTH, &enc_salt, &len2) != 0)
   {
      free(enc_key);
      fclose(f);
      fprintf(stderr, "setup_mock_master_key: base64 encode salt failed\n");
      return 1;
   }

   if (fprintf(f, "%s\n%s\n", enc_key, enc_salt) < 0)
   {
      free(enc_key);
      free(enc_salt);
      fclose(f);
      fprintf(stderr, "setup_mock_master_key: fprintf failed: %s\n", strerror(errno));
      return 1;
   }
   free(enc_key);
   free(enc_salt);
   fclose(f);
   chmod(path, 0600);
   return 0;
}

static void
teardown_mock_master_key(void)
{
   pgagroal_set_master_salt(NULL);
   if (temp_home[0] != '\0')
   {
      rm_rf(temp_home);
      if (original_home_set)
      {
         setenv("HOME", original_home, 1);
      }
      else
      {
         unsetenv("HOME");
      }
      memset(temp_home, 0, sizeof(temp_home));
   }
}

/**
 * Test: AES-256-GCM encrypt/decrypt round-trip.
 *
 * Encrypts a known plaintext string with a password, then decrypts
 * the ciphertext and verifies the output matches the original input.
 */
MCTF_TEST(test_aes_encrypt_decrypt_roundtrip)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "pgagroal-test-password-round-trip";
   char* password = "master-key-for-testing";
   char* ciphertext = NULL;
   int ciphertext_length = 0;
   char* decrypted = NULL;
   int ret_enc = 0;
   int ret_dec = 0;

   ret_enc = pgagroal_encrypt(plaintext, password, &ciphertext, &ciphertext_length, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_enc == 0, cleanup, "pgagroal_encrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext, cleanup, "ciphertext should not be NULL");
   MCTF_ASSERT(ciphertext_length > 0, cleanup, "ciphertext_length should be greater than 0");

   ret_dec = pgagroal_decrypt(ciphertext, ciphertext_length, password, &decrypted, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_dec == 0, cleanup, "pgagroal_decrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(decrypted, cleanup, "decrypted should not be NULL");
   MCTF_ASSERT_STR_EQ(decrypted, plaintext, cleanup, "decrypted text should match original plaintext");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: AES-192-GCM encrypt/decrypt round-trip.
 */
MCTF_TEST(test_aes_192_gcm_roundtrip)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "test-192-bit-mode-round-trip";
   char* password = "master-key-for-testing";
   char* ciphertext = NULL;
   int ciphertext_length = 0;
   char* decrypted = NULL;

   MCTF_ASSERT(pgagroal_encrypt(plaintext, password, &ciphertext, &ciphertext_length, ENCRYPTION_AES_192_GCM) == 0, cleanup, "Encryption failed");
   MCTF_ASSERT(pgagroal_decrypt(ciphertext, ciphertext_length, password, &decrypted, ENCRYPTION_AES_192_GCM) == 0, cleanup, "Decryption failed");
   MCTF_ASSERT_STR_EQ(decrypted, plaintext, cleanup, "Data mismatch");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: AES-128-GCM encrypt/decrypt round-trip.
 */
MCTF_TEST(test_aes_128_gcm_roundtrip)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "test-128-bit-mode-round-trip";
   char* password = "master-key-for-testing";
   char* ciphertext = NULL;
   int ciphertext_length = 0;
   char* decrypted = NULL;

   MCTF_ASSERT(pgagroal_encrypt(plaintext, password, &ciphertext, &ciphertext_length, ENCRYPTION_AES_128_GCM) == 0, cleanup, "Encryption failed");
   MCTF_ASSERT(pgagroal_decrypt(ciphertext, ciphertext_length, password, &decrypted, ENCRYPTION_AES_128_GCM) == 0, cleanup, "Decryption failed");
   MCTF_ASSERT_STR_EQ(decrypted, plaintext, cleanup, "Data mismatch");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: Salt verification — same password produces different ciphertext.
 *
 * Encrypts the exact same plaintext with the same password twice and
 * verifies that the two ciphertext outputs are different. This proves
 * the 16-byte random salt is working correctly.
 */
MCTF_TEST(test_aes_salt_produces_unique_ciphertext)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "identical-password-for-salt-test";
   char* password = "master-key-for-testing";
   char* ciphertext_a = NULL;
   int ciphertext_a_length = 0;
   char* ciphertext_b = NULL;
   int ciphertext_b_length = 0;
   int ret_a = 0;
   int ret_b = 0;
   int blobs_are_identical = 0;

   ret_a = pgagroal_encrypt(plaintext, password, &ciphertext_a, &ciphertext_a_length, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_a == 0, cleanup, "first pgagroal_encrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext_a, cleanup, "ciphertext_a should not be NULL");
   MCTF_ASSERT(ciphertext_a_length > 0, cleanup, "ciphertext_a_length should be greater than 0");

   ret_b = pgagroal_encrypt(plaintext, password, &ciphertext_b, &ciphertext_b_length, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_b == 0, cleanup, "second pgagroal_encrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext_b, cleanup, "ciphertext_b should not be NULL");
   MCTF_ASSERT(ciphertext_b_length > 0, cleanup, "ciphertext_b_length should be greater than 0");

   /* Same plaintext + same password must produce different ciphertext due to random salt */
   if (ciphertext_a_length == ciphertext_b_length)
   {
      blobs_are_identical = (memcmp(ciphertext_a, ciphertext_b, ciphertext_a_length) == 0);
   }

   MCTF_ASSERT(!blobs_are_identical, cleanup,
               "encrypting the same plaintext twice must produce different ciphertext (salt verification)");

cleanup:
   free(ciphertext_a);
   free(ciphertext_b);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: Decryption with wrong password does not leak plaintext.
 *
 * Encrypts data with one password and attempts to decrypt with a
 * different password.
 */
MCTF_TEST(test_aes_decrypt_wrong_password_no_leak)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "secret-data-wrong-password-test";
   char* correct_password = "correct-master-key";
   char* wrong_password = "wrong-master-key";
   char* ciphertext = NULL;
   int ciphertext_length = 0;
   char* decrypted = NULL;
   int ret_enc = 0;
   int ret_dec = 0;

   ret_enc = pgagroal_encrypt(plaintext, correct_password, &ciphertext, &ciphertext_length, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_enc == 0, cleanup, "pgagroal_encrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext, cleanup, "ciphertext should not be NULL");

   ret_dec = pgagroal_decrypt(ciphertext, ciphertext_length, wrong_password, &decrypted, ENCRYPTION_AES_256_GCM);

   /* GCM must fail authentication with wrong password */
   MCTF_ASSERT(ret_dec != 0, cleanup, "pgagroal_decrypt should fail with wrong password (GCM)");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted should be NULL on failure");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: Truncated ciphertext is rejected gracefully.
 *
 * Verifies that decryption fails if the input is shorter than the minimum
 * required length for GCM (salt + IV field + tag).
 */
MCTF_TEST(test_aes_decrypt_truncated_ciphertext_fails)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* password = "master-key-for-testing";
   char* decrypted = NULL;
   int ret = 0;

   /* Case 1: Extremely short buffer (10 bytes) */
   char truncated_buf_10[10];
   memset(truncated_buf_10, 0xAB, sizeof(truncated_buf_10));
   ret = pgagroal_decrypt(truncated_buf_10, sizeof(truncated_buf_10), password, &decrypted, ENCRYPTION_AES_256_GCM);
   MCTF_ASSERT(ret != 0, cleanup, "pgagroal_decrypt should reject ciphertext shorter than header + tag size (10 bytes)");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted should be NULL on failure");

   /* Case 2: Buffer with salt and partial IV (20 bytes) */
   char truncated_buf_20[20];
   memset(truncated_buf_20, 0xCD, sizeof(truncated_buf_20));
   ret = pgagroal_decrypt(truncated_buf_20, sizeof(truncated_buf_20), password, &decrypted, ENCRYPTION_AES_256_GCM);
   MCTF_ASSERT(ret != 0, cleanup, "pgagroal_decrypt should reject ciphertext shorter than header + tag size (20 bytes)");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted should be NULL on failure");

   /* Case 3: Buffer with header but no data/tag (28 bytes) */
   char truncated_buf_28[28];
   memset(truncated_buf_28, 0xEF, sizeof(truncated_buf_28));
   ret = pgagroal_decrypt(truncated_buf_28, sizeof(truncated_buf_28), password, &decrypted, ENCRYPTION_AES_256_GCM);
   MCTF_ASSERT(ret != 0, cleanup, "pgagroal_decrypt should reject ciphertext with missing data and tag (28 bytes)");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted should be NULL on failure");

cleanup:
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: AES-GCM authentication failure.
 *
 * Encrypts data with GCM, modifies the ciphertext (bit-flip),
 * and verifies that decryption fails due to tag mismatch.
 */
MCTF_TEST(test_aes_gcm_authentication_failure)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "highly-sensitive-data-for-gcm-test";
   char* password = "secure-password";
   char* ciphertext = NULL;
   int ciphertext_length = 0;
   char* decrypted = NULL;
   int ret_enc = 0;
   int ret_dec = 0;

   ret_enc = pgagroal_encrypt(plaintext, password, &ciphertext, &ciphertext_length, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_enc == 0, cleanup, "pgagroal_encrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext, cleanup, "ciphertext should not be NULL");
   MCTF_ASSERT(ciphertext_length >= PBKDF2_SALT_LENGTH + PBKDF2_IV_LENGTH + GCM_TAG_LENGTH, cleanup, "ciphertext_length should be greater than header + tag size");

   /* Flip a bit in the authentication tag at the end of the buffer */
   /* Format: [salt(16)][iv(12)][data...][tag(16)] */
   ciphertext[ciphertext_length - 8] ^= 0x01;

   ret_dec = pgagroal_decrypt(ciphertext, ciphertext_length, password, &decrypted, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_dec != 0, cleanup, "pgagroal_decrypt should fail if ciphertext is tampered (GCM)");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted should be NULL on authentication failure");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: AES-GCM tag tampering.
 */
MCTF_TEST(test_aes_gcm_tag_tampering_fails)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "data-to-protect";
   char* password = "password";
   char* ciphertext = NULL;
   int ciphertext_length = 0;
   char* decrypted = NULL;
   int ret_enc = 0;
   int ret_dec = 0;

   ret_enc = pgagroal_encrypt(plaintext, password, &ciphertext, &ciphertext_length, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_enc == 0, cleanup, "pgagroal_encrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext, cleanup, "ciphertext should not be NULL");
   MCTF_ASSERT(ciphertext_length >= PBKDF2_SALT_LENGTH + PBKDF2_IV_LENGTH + GCM_TAG_LENGTH, cleanup, "ciphertext_length should be greater than or equal to salt + iv + tag size");

   /* Tamper with the tag area (first byte of the tag at the end of the ciphertext) */
   ciphertext[ciphertext_length - GCM_TAG_LENGTH] ^= 0xFF;

   ret_dec = pgagroal_decrypt(ciphertext, ciphertext_length, password, &decrypted, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_dec != 0, cleanup, "pgagroal_decrypt should fail if tag is tampered");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted buffer should be NULL on authentication failure (tag tampering)");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: Buffer encrypt/decrypt round-trip (wire protocol).
 */
MCTF_TEST(test_aes_buffer_roundtrip)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "wire-protocol-buffer-test";
   size_t plaintext_len = strlen(plaintext);
   unsigned char* ciphertext = NULL;
   size_t ciphertext_len = 0;
   unsigned char* decrypted = NULL;
   size_t decrypted_len = 0;

   /* Test AES-256-GCM (default for management) */
   MCTF_ASSERT(pgagroal_encrypt_buffer((unsigned char*)plaintext, plaintext_len, &ciphertext, &ciphertext_len, ENCRYPTION_AES_256_GCM) == 0, cleanup, "pgagroal_encrypt_buffer should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext, cleanup, "ciphertext should not be NULL");
   MCTF_ASSERT(ciphertext_len >= PBKDF2_SALT_LENGTH + PBKDF2_IV_LENGTH + GCM_TAG_LENGTH, cleanup, "ciphertext should contain salt, iv and tag");

   MCTF_ASSERT(pgagroal_decrypt_buffer(ciphertext, ciphertext_len, &decrypted, &decrypted_len, ENCRYPTION_AES_256_GCM) == 0, cleanup, "pgagroal_decrypt_buffer should succeed");
   MCTF_ASSERT_PTR_NONNULL(decrypted, cleanup, "decrypted buffer should not be NULL");
   MCTF_ASSERT(decrypted_len == plaintext_len, cleanup, "decrypted length should match original");
   MCTF_ASSERT(memcmp(decrypted, plaintext, plaintext_len) == 0, cleanup, "decrypted content should match original");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: Buffer encryption tamper detection.
 */
MCTF_TEST_NEGATIVE(test_aes_buffer_tamper_fails)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "tamper-test-data";
   size_t plaintext_len = strlen(plaintext);
   unsigned char* ciphertext = NULL;
   size_t ciphertext_len = 0;
   unsigned char* decrypted = NULL;
   size_t decrypted_len = 0;

   MCTF_ASSERT(pgagroal_encrypt_buffer((unsigned char*)plaintext, plaintext_len, &ciphertext, &ciphertext_len, ENCRYPTION_AES_256_GCM) == 0, cleanup, "pgagroal_encrypt_buffer should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext, cleanup, "ciphertext should not be NULL");
   MCTF_ASSERT(ciphertext_len >= PBKDF2_SALT_LENGTH + PBKDF2_IV_LENGTH + GCM_TAG_LENGTH, cleanup, "ciphertext should contain salt, iv and tag");

   /* Tamper with the tag area (first byte of the tag at the end of the ciphertext) */
   ciphertext[ciphertext_len - GCM_TAG_LENGTH] ^= 0x42;

   MCTF_ASSERT(pgagroal_decrypt_buffer(ciphertext, ciphertext_len, &decrypted, &decrypted_len, ENCRYPTION_AES_256_GCM) != 0, cleanup, "pgagroal_decrypt_buffer should fail on tampered tag");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted buffer should be NULL on failure");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: Buffer encryption with empty payload.
 */
MCTF_TEST(test_aes_buffer_empty_payload)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "";
   size_t plaintext_len = 0;
   unsigned char* ciphertext = NULL;
   size_t ciphertext_len = 0;
   unsigned char* decrypted = NULL;
   size_t decrypted_len = 0;

   MCTF_ASSERT(pgagroal_encrypt_buffer((unsigned char*)plaintext, plaintext_len, &ciphertext, &ciphertext_len, ENCRYPTION_AES_256_GCM) == 0, cleanup, "pgagroal_encrypt_buffer should succeed for empty payload");
   MCTF_ASSERT(ciphertext_len == PBKDF2_SALT_LENGTH + PBKDF2_IV_LENGTH + GCM_TAG_LENGTH, cleanup, "ciphertext_len should be exactly salt + iv + tag");

   MCTF_ASSERT(pgagroal_decrypt_buffer(ciphertext, ciphertext_len, &decrypted, &decrypted_len, ENCRYPTION_AES_256_GCM) == 0, cleanup, "pgagroal_decrypt_buffer should succeed for empty payload");
   MCTF_ASSERT(decrypted_len == 0, cleanup, "decrypted_len should be 0");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}

/**
 * Test: Master Salt Mutation Failure
 *
 * Encrypts data with GCM, flips a bit in the salt preamble, 
 * and verifies that decryption fails to protect against salt tampering.
 */
MCTF_TEST(test_aes_salt_mutation_fails)
{
   MCTF_ASSERT(setup_mock_master_key() == 0, cleanup, "mock master key setup failed");
   char* plaintext = "salt-tamper-test-data";
   char* password = "secure-password";
   char* ciphertext = NULL;
   int ciphertext_length = 0;
   char* decrypted = NULL;
   int ret_dec = 0;

   MCTF_ASSERT(pgagroal_encrypt(plaintext, password, &ciphertext, &ciphertext_length, ENCRYPTION_AES_256_GCM) == 0, cleanup, "encrypt should succeed");
   MCTF_ASSERT_PTR_NONNULL(ciphertext, cleanup, "ciphertext non-null");

   /* Tamper with the salt (first byte of the buffer) */
   ciphertext[0] ^= 0x42;

   ret_dec = pgagroal_decrypt(ciphertext, ciphertext_length, password, &decrypted, ENCRYPTION_AES_256_GCM);

   MCTF_ASSERT(ret_dec != 0, cleanup, "decrypt should fail on tampered salt");
   MCTF_ASSERT_PTR_NULL(decrypted, cleanup, "decrypted buffer should be NULL");

cleanup:
   free(ciphertext);
   free(decrypted);
   teardown_mock_master_key();
   MCTF_FINISH();
}
