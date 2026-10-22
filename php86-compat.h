/* PHP 8.6 extension compatibility shim.
 * Several PECL extensions still use macros/helpers removed in 8.6.
 * Force-included via CPPFLAGS for PHP 8.6 extension builds only. */
#ifndef PHP86_EXT_COMPAT_H
#define PHP86_EXT_COMPAT_H

#include <stddef.h>

#ifndef XtOffsetOf
#define XtOffsetOf(s_type, m_name) offsetof(s_type, m_name)
#endif

#ifndef zval_dtor
#define zval_dtor(zv) zval_ptr_dtor(zv)
#endif

#ifndef zval_is_true
#define zval_is_true(zv) zend_is_true(zv)
#endif

#ifndef INI_STR
#define INI_STR(name) zend_ini_string(name, 0, 0)
#endif

#ifndef INI_INT
#define INI_INT(name) zend_ini_long(name, 0, 0)
#endif

#ifndef INI_FLT
#define INI_FLT(name) zend_ini_double(name, 0, 0)
#endif

#ifndef INI_BOOL
#define INI_BOOL(name) (zend_ini_long(name, 0, 0) != 0)
#endif

#ifndef EMPTY_SWITCH_DEFAULT_CASE
#define EMPTY_SWITCH_DEFAULT_CASE() default: ZEND_UNREACHABLE();
#endif

#ifndef ZEND_WRONG_PARAM_COUNT
#define ZEND_WRONG_PARAM_COUNT zend_wrong_param_count
#endif

#ifndef WRONG_PARAM_COUNT
#define WRONG_PARAM_COUNT zend_wrong_param_count
#endif

#ifndef php_hash_bin2hex
#define php_hash_bin2hex zend_bin2hex
#endif

#endif /* PHP86_EXT_COMPAT_H */
