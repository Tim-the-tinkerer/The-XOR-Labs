/*
 * Thin wrapper around the official PHC Argon2id implementation
 * (phc-winner-argon2 20190702). The 32-byte results match that code,
 * including the secret-key input, so existing XOP1 archives stay readable.
 *
 * PHC Argon2 is licensed CC0 1.0 or Apache 2.0, at your option.
 * See LICENSE in this directory.
 */

#include "argon2.h"
#include <stdint.h>
#include <string.h>

static int derive(const uint8_t *pwd, size_t pwdlen,
                   const uint8_t *salt, size_t saltlen,
                   const uint8_t *secret, size_t secretlen,
                   const uint8_t *ad, size_t adlen,
                   uint32_t t_cost, uint32_t m_cost_kib, uint32_t parallelism,
                   uint8_t *out, size_t outlen) {
    if (out == NULL || outlen < 4 || outlen > UINT32_MAX) return 1;
    if (pwdlen > UINT32_MAX || saltlen > UINT32_MAX || secretlen > UINT32_MAX || adlen > UINT32_MAX) {
        return 1;
    }
    if ((pwdlen && pwd == NULL) || (saltlen && salt == NULL) ||
        (secretlen && secret == NULL) || (adlen && ad == NULL)) {
        return 1;
    }

    argon2_context ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.out = out;
    ctx.outlen = (uint32_t)outlen;
    ctx.pwd = (uint8_t *)pwd;
    ctx.pwdlen = (uint32_t)pwdlen;
    ctx.salt = (uint8_t *)salt;
    ctx.saltlen = (uint32_t)saltlen;
    ctx.secret = (uint8_t *)secret;
    ctx.secretlen = (uint32_t)secretlen;
    ctx.ad = (uint8_t *)ad;
    ctx.adlen = (uint32_t)adlen;
    ctx.t_cost = t_cost;
    ctx.m_cost = m_cost_kib;
    ctx.lanes = parallelism;
    ctx.threads = parallelism;
    ctx.version = ARGON2_VERSION_13;
    /* Do not ask the library to wipe the caller's buffers. Swift wipes its copies. */
    ctx.flags = ARGON2_DEFAULT_FLAGS;

    return argon2_ctx(&ctx, Argon2_id) == ARGON2_OK ? 0 : 1;
}

int xorpass_argon2id_raw(const uint8_t *pwd, size_t pwdlen,
                         const uint8_t *salt, size_t saltlen,
                         uint32_t t_cost, uint32_t m_cost_kib, uint32_t parallelism,
                         uint8_t *out, size_t outlen) {
    return derive(pwd, pwdlen, salt, saltlen, NULL, 0, NULL, 0,
                  t_cost, m_cost_kib, parallelism, out, outlen);
}

int xorpass_argon2id_raw_ex(const uint8_t *pwd, size_t pwdlen,
                            const uint8_t *salt, size_t saltlen,
                            const uint8_t *secret, size_t secretlen,
                            const uint8_t *ad, size_t adlen,
                            uint32_t t_cost, uint32_t m_cost_kib, uint32_t parallelism,
                            uint8_t *out, size_t outlen) {
    return derive(pwd, pwdlen, salt, saltlen, secret, secretlen, ad, adlen,
                  t_cost, m_cost_kib, parallelism, out, outlen);
}
