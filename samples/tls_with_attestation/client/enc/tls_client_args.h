/*
 *  This file is auto generated by oeedger8r. DO NOT EDIT.
 */
#ifndef TLS_CLIENT_ARGS_H
#define TLS_CLIENT_ARGS_H

#include <stdint.h>
#include <stdlib.h> /* for wchar_t */ 

#include <openenclave/bits/result.h>

typedef struct _launch_tls_client_args_t {
	int _retval;
	char* server_name;
	size_t server_name_len;
	char* server_port;
	size_t server_port_len;
    oe_result_t _result;
 } launch_tls_client_args_t;

/* trusted function ids */
enum {
    fcn_id_launch_tls_client = 0,
    fcn_id_trusted_call_id_max = OE_ENUM_MAX
};


/* untrusted function ids */
enum {
    fcn_id_untrusted_call_max = OE_ENUM_MAX
};


#endif // TLS_CLIENT_ARGS_H