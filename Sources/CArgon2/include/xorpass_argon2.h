#ifndef XORPASS_ARGON2_H
#define XORPASS_ARGON2_H

#include <stddef.h>
#include <stdint.h>

/*
 * Argon2id raw key derivation (RFC 9106).
 *
 * Returns 0 on success, non-zero on error (bad parameters or allocation
 * failure). `out` receives exactly `outlen` bytes of derived key material.
 * m_cost_kib is memory in kibibytes. Version is 0x13. No secret and no
 * associated data in the primary entry point.
 */
int xorpass_argon2id_raw(const uint8_t *pwd, size_t pwdlen,
                         const uint8_t *salt, size_t saltlen,
                         uint32_t t_cost, uint32_t m_cost_kib, uint32_t parallelism,
                         uint8_t *out, size_t outlen);

/* Extended form with optional secret key and associated data (RFC 9106 KAT). */
int xorpass_argon2id_raw_ex(const uint8_t *pwd, size_t pwdlen,
                            const uint8_t *salt, size_t saltlen,
                            const uint8_t *secret, size_t secretlen,
                            const uint8_t *ad, size_t adlen,
                            uint32_t t_cost, uint32_t m_cost_kib, uint32_t parallelism,
                            uint8_t *out, size_t outlen);

#endif
