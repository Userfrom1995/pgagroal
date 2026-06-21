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

#include <pgagroal.h>
#include <tls.h>
#include <logging.h>

#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/x509.h>

static int
classify(SSL* ssl, int rc)
{
   int err = SSL_get_error(ssl, rc);

   switch (err)
   {
      case SSL_ERROR_WANT_READ:
      case SSL_ERROR_WANT_WRITE:
         return PGAGROAL_TLS_WANT_IO;
      case SSL_ERROR_ZERO_RETURN:
         return PGAGROAL_TLS_CLOSED;
      default:
         return PGAGROAL_TLS_ERROR;
   }
}

int
pgagroal_tls_create(SSL_CTX* ctx, bool server, struct tls** tls)
{
   struct tls* t = NULL;

   if (ctx == NULL || tls == NULL)
   {
      goto error;
   }

   *tls = NULL;

   t = (struct tls*)calloc(1, sizeof(struct tls));
   if (t == NULL)
   {
      goto error;
   }

   t->server = server;
   t->handshake_complete = false;
   t->fd = -1;

   t->ssl = SSL_new(ctx);
   if (t->ssl == NULL)
   {
      goto error;
   }

   t->rbio = BIO_new(BIO_s_mem());
   t->wbio = BIO_new(BIO_s_mem());
   if (t->rbio == NULL || t->wbio == NULL)
   {
      goto error;
   }

   /* An empty memory BIO should ask for more bytes, not signal EOF */
   BIO_set_mem_eof_return(t->rbio, -1);
   BIO_set_mem_eof_return(t->wbio, -1);

   /* The SSL object takes ownership of both BIOs */
   SSL_set_bio(t->ssl, t->rbio, t->wbio);

   /* Back-pointer so the I/O layer can recover the wrapper from the SSL object */
   SSL_set_app_data(t->ssl, t);

   if (server)
   {
      SSL_set_accept_state(t->ssl);
   }
   else
   {
      SSL_set_connect_state(t->ssl);
   }

   *tls = t;
   return PGAGROAL_TLS_OK;

error:
   if (t != NULL)
   {
      if (t->ssl != NULL)
      {
         SSL_free(t->ssl);
      }
      else
      {
         if (t->rbio != NULL)
         {
            BIO_free(t->rbio);
         }
         if (t->wbio != NULL)
         {
            BIO_free(t->wbio);
         }
      }
      free(t);
   }

   return PGAGROAL_TLS_ERROR;
}

void
pgagroal_tls_free(struct tls* tls)
{
   if (tls == NULL)
   {
      return;
   }

   if (tls->ssl != NULL)
   {
      /* Frees the SSL object and the two BIOs it owns */
      SSL_free(tls->ssl);
   }

   free(tls);
}

void
pgagroal_tls_set_fd(struct tls* tls, int fd)
{
   tls->fd = fd;
}

struct tls*
pgagroal_tls_from_ssl(SSL* ssl)
{
   if (ssl == NULL)
   {
      return NULL;
   }

   return (struct tls*)SSL_get_app_data(ssl);
}

int
pgagroal_tls_feed(struct tls* tls, const void* buf, size_t len, size_t* consumed)
{
   int written;

   if (consumed != NULL)
   {
      *consumed = 0;
   }

   if (tls == NULL || tls->rbio == NULL || (buf == NULL && len > 0))
   {
      return PGAGROAL_TLS_ERROR;
   }

   if (len == 0)
   {
      return PGAGROAL_TLS_OK;
   }

   written = BIO_write(tls->rbio, buf, (int)len);
   if (written <= 0)
   {
      return PGAGROAL_TLS_ERROR;
   }

   if (consumed != NULL)
   {
      *consumed = (size_t)written;
   }

   return PGAGROAL_TLS_OK;
}

int
pgagroal_tls_drain(struct tls* tls, void* buf, size_t cap, size_t* produced)
{
   int nread;

   if (produced != NULL)
   {
      *produced = 0;
   }

   if (tls == NULL || tls->wbio == NULL || buf == NULL)
   {
      return PGAGROAL_TLS_ERROR;
   }

   if (cap == 0)
   {
      return PGAGROAL_TLS_OK;
   }

   nread = BIO_read(tls->wbio, buf, (int)cap);
   if (nread <= 0)
   {
      /* Nothing queued is not an error for a memory BIO */
      if (BIO_should_retry(tls->wbio))
      {
         return PGAGROAL_TLS_OK;
      }
      return PGAGROAL_TLS_ERROR;
   }

   if (produced != NULL)
   {
      *produced = (size_t)nread;
   }

   return PGAGROAL_TLS_OK;
}

bool
pgagroal_tls_pending(struct tls* tls)
{
   if (tls == NULL || tls->wbio == NULL)
   {
      return false;
   }

   return BIO_pending(tls->wbio) > 0;
}

int
pgagroal_tls_handshake(struct tls* tls)
{
   int rc;

   if (tls == NULL || tls->ssl == NULL)
   {
      return PGAGROAL_TLS_ERROR;
   }

   if (tls->handshake_complete)
   {
      return PGAGROAL_TLS_OK;
   }

   rc = SSL_do_handshake(tls->ssl);
   if (rc == 1)
   {
      tls->handshake_complete = true;
      return PGAGROAL_TLS_OK;
   }

   return classify(tls->ssl, rc);
}

int
pgagroal_tls_write(struct tls* tls, const void* buf, size_t len, size_t* written)
{
   int rc;

   if (written != NULL)
   {
      *written = 0;
   }

   if (tls == NULL || tls->ssl == NULL || (buf == NULL && len > 0))
   {
      return PGAGROAL_TLS_ERROR;
   }

   if (len == 0)
   {
      return PGAGROAL_TLS_OK;
   }

   rc = SSL_write(tls->ssl, buf, (int)len);
   if (rc > 0)
   {
      if (written != NULL)
      {
         *written = (size_t)rc;
      }
      return PGAGROAL_TLS_OK;
   }

   return classify(tls->ssl, rc);
}

int
pgagroal_tls_read(struct tls* tls, void* buf, size_t cap, size_t* nread)
{
   int rc;

   if (nread != NULL)
   {
      *nread = 0;
   }

   if (tls == NULL || tls->ssl == NULL || buf == NULL)
   {
      return PGAGROAL_TLS_ERROR;
   }

   if (cap == 0)
   {
      return PGAGROAL_TLS_OK;
   }

   rc = SSL_read(tls->ssl, buf, (int)cap);
   if (rc > 0)
   {
      if (nread != NULL)
      {
         *nread = (size_t)rc;
      }
      return PGAGROAL_TLS_OK;
   }

   return classify(tls->ssl, rc);
}

static int
socket_write_all(int fd, const unsigned char* buf, size_t len)
{
   size_t off = 0;

   while (off < len)
   {
      ssize_t n = write(fd, buf + off, len - off);
      if (n > 0)
      {
         off += (size_t)n;
      }
      else if (n < 0 && errno == EINTR)
      {
         continue;
      }
      else
      {
         return PGAGROAL_TLS_ERROR;
      }
   }

   return PGAGROAL_TLS_OK;
}

/* Drain all pending outbound ciphertext to the socket. */
static int
socket_flush(struct tls* tls, int fd)
{
   unsigned char buf[16384];
   size_t produced = 0;

   while (pgagroal_tls_drain(tls, buf, sizeof(buf), &produced) == PGAGROAL_TLS_OK && produced > 0)
   {
      if (socket_write_all(fd, buf, produced) != PGAGROAL_TLS_OK)
      {
         return PGAGROAL_TLS_ERROR;
      }
   }

   return PGAGROAL_TLS_OK;
}

/* Read one chunk of ciphertext from the socket and feed it to the engine. */
static int
socket_fill(struct tls* tls, int fd)
{
   unsigned char buf[16384];
   ssize_t n;

   do
   {
      n = read(fd, buf, sizeof(buf));
   }
   while (n < 0 && errno == EINTR);

   if (n <= 0)
   {
      return PGAGROAL_TLS_ERROR;
   }

   return pgagroal_tls_feed(tls, buf, (size_t)n, NULL);
}

int
pgagroal_tls_socket_handshake(struct tls* tls, int fd)
{
   if (tls == NULL || fd < 0)
   {
      return PGAGROAL_TLS_ERROR;
   }

   for (;;)
   {
      int rc = pgagroal_tls_handshake(tls);

      if (socket_flush(tls, fd) != PGAGROAL_TLS_OK)
      {
         return PGAGROAL_TLS_ERROR;
      }

      if (rc == PGAGROAL_TLS_OK)
      {
         return PGAGROAL_TLS_OK;
      }
      if (rc != PGAGROAL_TLS_WANT_IO)
      {
         return PGAGROAL_TLS_ERROR;
      }

      if (socket_fill(tls, fd) != PGAGROAL_TLS_OK)
      {
         return PGAGROAL_TLS_ERROR;
      }
   }
}

int
pgagroal_tls_socket_read(struct tls* tls, int fd, void* buf, size_t cap, size_t* nread)
{
   if (nread != NULL)
   {
      *nread = 0;
   }

   if (tls == NULL || fd < 0 || buf == NULL)
   {
      return PGAGROAL_TLS_ERROR;
   }

   for (;;)
   {
      int rc = pgagroal_tls_read(tls, buf, cap, nread);

      if (rc == PGAGROAL_TLS_OK || rc == PGAGROAL_TLS_CLOSED)
      {
         return rc;
      }
      if (rc != PGAGROAL_TLS_WANT_IO)
      {
         return PGAGROAL_TLS_ERROR;
      }

      /* The engine may owe the peer a flight before it can receive more. */
      if (socket_flush(tls, fd) != PGAGROAL_TLS_OK)
      {
         return PGAGROAL_TLS_ERROR;
      }
      if (socket_fill(tls, fd) != PGAGROAL_TLS_OK)
      {
         return PGAGROAL_TLS_ERROR;
      }
   }
}

int
pgagroal_tls_socket_write(struct tls* tls, int fd, const void* buf, size_t len)
{
   size_t off = 0;

   if (tls == NULL || fd < 0 || (buf == NULL && len > 0))
   {
      return PGAGROAL_TLS_ERROR;
   }

   while (off < len)
   {
      size_t written = 0;
      int rc = pgagroal_tls_write(tls, (const unsigned char*)buf + off, len - off, &written);

      if (rc == PGAGROAL_TLS_OK)
      {
         off += written;
         if (socket_flush(tls, fd) != PGAGROAL_TLS_OK)
         {
            return PGAGROAL_TLS_ERROR;
         }
      }
      else if (rc == PGAGROAL_TLS_WANT_IO)
      {
         if (socket_flush(tls, fd) != PGAGROAL_TLS_OK)
         {
            return PGAGROAL_TLS_ERROR;
         }
         if (socket_fill(tls, fd) != PGAGROAL_TLS_OK)
         {
            return PGAGROAL_TLS_ERROR;
         }
      }
      else
      {
         return PGAGROAL_TLS_ERROR;
      }
   }

   return PGAGROAL_TLS_OK;
}

int
pgagroal_tls_configure_server_ctx(SSL_CTX* ctx, char* key_file, char* cert_file, char* ca_file)
{
   STACK_OF(X509_NAME)* root_cert_list = NULL;

   if (strlen(cert_file) == 0)
   {
      pgagroal_log_error("No TLS certificate defined");
      goto error;
   }

   if (strlen(key_file) == 0)
   {
      pgagroal_log_error("No TLS private key defined");
      goto error;
   }

   if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1)
   {
      unsigned long err;

      err = ERR_get_error();
      pgagroal_log_error("Couldn't load TLS certificate: %s", cert_file);
      pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
      goto error;
   }

   if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1)
   {
      unsigned long err;

      err = ERR_get_error();
      pgagroal_log_error("Couldn't load TLS private key: %s", key_file);
      pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
      goto error;
   }

   if (SSL_CTX_check_private_key(ctx) != 1)
   {
      unsigned long err;

      err = ERR_get_error();
      pgagroal_log_error("TLS private key check failed: %s", key_file);
      pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
      goto error;
   }

   if (strlen(ca_file) > 0)
   {
      if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS CA: %s", ca_file);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      root_cert_list = SSL_load_client_CA_file(ca_file);
      if (root_cert_list == NULL)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS CA: %s", ca_file);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      SSL_CTX_set_verify(ctx, (SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT | SSL_VERIFY_CLIENT_ONCE), NULL);
      SSL_CTX_set_client_CA_list(ctx, root_cert_list);
   }

   return 0;

error:

   return 1;
}

int
pgagroal_tls_create_server(SSL_CTX* ctx, char* key_file, char* cert_file, char* ca_file, struct tls** tls)
{
   if (pgagroal_tls_configure_server_ctx(ctx, key_file, cert_file, ca_file))
   {
      goto error;
   }

   if (pgagroal_tls_create(ctx, true, tls) != PGAGROAL_TLS_OK)
   {
      goto error;
   }

   return 0;

error:

   SSL_CTX_free(ctx);

   return 1;
}

int
pgagroal_tls_create_client(SSL_CTX* ctx, char* key, char* cert, char* root, struct tls** tls)
{
   struct tls* t = NULL;
   bool have_cert = false;
   bool have_rootcert = false;

   if (root != NULL && strlen(root) > 0)
   {
      if (SSL_CTX_load_verify_locations(ctx, root, NULL) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS CA: %s", root);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      have_rootcert = true;
   }

   if (cert != NULL && strlen(cert) > 0)
   {
      if (SSL_CTX_use_certificate_chain_file(ctx, cert) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS certificate: %s", cert);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      have_cert = true;
   }

   if (pgagroal_tls_create(ctx, false, &t) != PGAGROAL_TLS_OK)
   {
      goto error;
   }

   if (have_cert && key != NULL && strlen(key) > 0)
   {
      if (SSL_use_PrivateKey_file(t->ssl, key, SSL_FILETYPE_PEM) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS private key: %s", key);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      if (SSL_check_private_key(t->ssl) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("TLS private key check failed: %s", key);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }
   }

   if (have_rootcert)
   {
      SSL_set_verify(t->ssl, SSL_VERIFY_PEER | SSL_VERIFY_CLIENT_ONCE, NULL);
   }

   *tls = t;

   return 0;

error:

   if (t != NULL)
   {
      pgagroal_tls_free(t);
   }
   SSL_CTX_free(ctx);

   return 1;
}

int
pgagroal_create_ssl_ctx(bool client, SSL_CTX** ctx)
{
   SSL_CTX* c = NULL;

   if (client)
   {
      c = SSL_CTX_new(TLS_client_method());
   }
   else
   {
      c = SSL_CTX_new(TLS_server_method());
   }

   if (c == NULL)
   {
      goto error;
   }

   if (SSL_CTX_set_min_proto_version(c, TLS1_2_VERSION) == 0)
   {
      goto error;
   }

   SSL_CTX_set_mode(c, SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
   SSL_CTX_set_options(c, SSL_OP_NO_TICKET);
   SSL_CTX_set_session_cache_mode(c, SSL_SESS_CACHE_CLIENT | SSL_SESS_CACHE_NO_INTERNAL_STORE);

   *ctx = c;

   return 0;

error:

   if (c != NULL)
   {
      SSL_CTX_free(c);
   }

   return 1;
}

int
pgagroal_create_ssl_server(SSL_CTX* ctx, char* key_file, char* cert_file, char* ca_file, int socket, SSL** ssl)
{
   SSL* s = NULL;

   if (pgagroal_tls_configure_server_ctx(ctx, key_file, cert_file, ca_file))
   {
      goto error;
   }

   s = SSL_new(ctx);

   if (s == NULL)
   {
      goto error;
   }

   if (SSL_set_fd(s, socket) == 0)
   {
      goto error;
   }

   *ssl = s;

   return 0;

error:

   if (s != NULL)
   {
      SSL_shutdown(s);
      SSL_free(s);
   }
   SSL_CTX_free(ctx);

   return 1;
}

int
pgagroal_create_ssl_client(SSL_CTX* ctx, char* key, char* cert, char* root, int socket, SSL** ssl)
{
   SSL* s = NULL;
   bool have_cert = false;
   bool have_rootcert = false;

   if (root != NULL && strlen(root) > 0)
   {
      if (SSL_CTX_load_verify_locations(ctx, root, NULL) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS CA: %s", root);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      have_rootcert = true;
   }

   if (cert != NULL && strlen(cert) > 0)
   {
      if (SSL_CTX_use_certificate_chain_file(ctx, cert) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS certificate: %s", cert);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      have_cert = true;
   }

   s = SSL_new(ctx);

   if (s == NULL)
   {
      goto error;
   }

   if (SSL_set_fd(s, socket) == 0)
   {
      goto error;
   }

   if (have_cert && key != NULL && strlen(key) > 0)
   {
      if (SSL_use_PrivateKey_file(s, key, SSL_FILETYPE_PEM) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("Couldn't load TLS private key: %s", key);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }

      if (SSL_check_private_key(s) != 1)
      {
         unsigned long err;

         err = ERR_get_error();
         pgagroal_log_error("TLS private key check failed: %s", key);
         pgagroal_log_error("Reason: %s", ERR_reason_error_string(err));
         goto error;
      }
   }

   if (have_rootcert)
   {
      SSL_set_verify(s, SSL_VERIFY_PEER | SSL_VERIFY_CLIENT_ONCE, NULL);
   }

   *ssl = s;

   return 0;

error:

   if (s != NULL)
   {
      SSL_shutdown(s);
      SSL_free(s);
   }
   SSL_CTX_free(ctx);

   return 1;
}
