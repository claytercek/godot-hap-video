/*
 * Minimalist C++ test header for headless core tests.
 * Provides simple assertion macros and a test runner, no framework dependencies.
 */

#ifndef HAP_CORE_TEST_H
#define HAP_CORE_TEST_H

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace hap {
namespace test {

inline int &fail_count() {
  static int count = 0;
  return count;
}

inline int &test_count() {
  static int count = 0;
  return count;
}

#define HAP_TEST(name)                                                       \
  static void hap_test_##name();                                            \
  namespace {                                                                \
  struct hap_test_registrar_##name {                                        \
    hap_test_registrar_##name() {                                           \
      hap::test::test_count()++;                                            \
      fprintf(stderr, "  TEST: %s ... ", #name);                            \
      int before = hap::test::fail_count();                                 \
      hap_test_##name();                                                    \
      fprintf(stderr, "%s\n", hap::test::fail_count() > before ? "FAIL" : "OK"); \
    }                                                                        \
  } hap_test_reg_##name;                                                    \
  }                                                                          \
  static void hap_test_##name()

#define HAP_ASSERT(cond)                                                    \
  do {                                                                      \
    if (!(cond)) {                                                          \
      fprintf(stderr, "\nFAIL at %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
      hap::test::fail_count()++;                                            \
    }                                                                       \
  } while (0)

#define HAP_ASSERT_EQ(a, b)                                                 \
  do {                                                                      \
    auto _a = (a);                                                          \
    auto _b = (b);                                                          \
    if (_a != _b) {                                                         \
      fprintf(stderr, "\nFAIL at %s:%d: %s == %s\n", __FILE__, __LINE__,    \
              #a, #b);                                                      \
      hap::test::fail_count()++;                                            \
    }                                                                       \
  } while (0)

inline int run_all() {
  fprintf(stderr, "\nRunning %d tests...\n", test_count());
  if (fail_count() > 0) {
    fprintf(stderr, "\n%d/%d tests FAILED\n", fail_count(), test_count());
    return 1;
  }
  fprintf(stderr, "\nAll %d tests passed\n", test_count());
  return 0;
}

} // namespace test
} // namespace hap

#endif // HAP_CORE_TEST_H
