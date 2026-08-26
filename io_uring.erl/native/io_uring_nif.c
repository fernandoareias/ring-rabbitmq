#define _GNU_SOURCE
#include <erl_nif.h>
#include <liburing.h>
#include <string.h>
#include <errno.h>
#include <netinet/in.h>

static ErlNifResourceType *RING_RES_TYPE = NULL;
static ErlNifResourceType *CQE_RES_TYPE  = NULL;

typedef struct {
    struct io_uring  ring;
    int              initialised;
    ErlNifMutex     *sq_lock;
    ErlNifMutex     *cq_lock;
    struct iovec    *reg_bufs;
    void           **reg_buf_data;
    int              reg_buf_count;
    int             *reg_fds;
    int              reg_fd_count;
} ring_res_t;

typedef struct {
    ErlNifEnv    *env;           /* owns tag_term */
    ERL_NIF_TERM  tag;           /* caller-supplied correlation tag */
    ErlNifBinary *recv_buf;      /* for read/recv: pre-allocated recv buffer */
    void         *aux_buf;       /* for write/send/connect: persistent copy */
    int           fixed_buf_idx; /* >= 0 for read_fixed: index into reg_bufs */
} sqe_ctx_t;

typedef struct {
    struct io_uring_cqe *cqe;
    sqe_ctx_t           *ctx;
    ring_res_t          *ring_res;
} cqe_res_t;


static void ring_destructor(ErlNifEnv *env, void *obj)
{
    (void)env;
    ring_res_t *r = (ring_res_t *)obj;
    if (r->initialised) {
        io_uring_queue_exit(&r->ring);
        r->initialised = 0;
    }
    if (r->sq_lock) { enif_mutex_destroy(r->sq_lock); r->sq_lock = NULL; }
    if (r->cq_lock) { enif_mutex_destroy(r->cq_lock); r->cq_lock = NULL; }
    if (r->reg_buf_data) {
        for (int i = 0; i < r->reg_buf_count; i++)
            if (r->reg_buf_data[i]) enif_free(r->reg_buf_data[i]);
        enif_free(r->reg_buf_data);
        r->reg_buf_data = NULL;
    }
    if (r->reg_bufs) { enif_free(r->reg_bufs); r->reg_bufs = NULL; }
    if (r->reg_fds)  { enif_free(r->reg_fds);  r->reg_fds  = NULL; }
}

static void sqe_ctx_free(sqe_ctx_t *ctx)
{
    if (!ctx) return;
    if (ctx->env)      { enif_free_env(ctx->env); ctx->env = NULL; }
    if (ctx->recv_buf) { enif_release_binary(ctx->recv_buf);
                         enif_free(ctx->recv_buf); ctx->recv_buf = NULL; }
    if (ctx->aux_buf)  { enif_free(ctx->aux_buf); ctx->aux_buf = NULL; }
    enif_free(ctx);
}

static void cqe_destructor(ErlNifEnv *env, void *obj)
{
    (void)env;
    cqe_res_t *r = (cqe_res_t *)obj;
    sqe_ctx_free(r->ctx);
    r->ctx = NULL;
    if (r->ring_res) {
        enif_release_resource(r->ring_res);
        r->ring_res = NULL;
    }
}


static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_undefined;
static ERL_NIF_TERM atom_full;
static ERL_NIF_TERM atom_unknown_op;

static sqe_ctx_t *
ctx_alloc(ErlNifEnv *env __attribute__((unused)), ERL_NIF_TERM tag)
{
    sqe_ctx_t *ctx = enif_alloc(sizeof(sqe_ctx_t));
    if (!ctx) return NULL;
    memset(ctx, 0, sizeof(*ctx));
    ctx->fixed_buf_idx = -1;
    ctx->env = enif_alloc_env();
    if (!ctx->env) { enif_free(ctx); return NULL; }
    ctx->tag = enif_make_copy(ctx->env, tag);
    return ctx;
}

static ERL_NIF_TERM
nif_setup(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned entries, flags;

    if (argc != 2)                              return enif_make_badarg(env);
    if (!enif_get_uint(env, argv[0], &entries)) return enif_make_badarg(env);
    if (!enif_get_uint(env, argv[1], &flags))   return enif_make_badarg(env);

    ring_res_t *res = enif_alloc_resource(RING_RES_TYPE, sizeof(ring_res_t));
    if (!res)
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "enomem"));

    memset(res, 0, sizeof(*res));

    int rc = io_uring_queue_init(entries, &res->ring, flags);
    if (rc < 0) {
        enif_release_resource(res);
        return enif_make_tuple2(env, atom_error, enif_make_int(env, -rc));
    }

    res->initialised = 1;
    res->sq_lock = enif_mutex_create("io_uring_sq");
    res->cq_lock = enif_mutex_create("io_uring_cq");
    if (!res->sq_lock || !res->cq_lock) {
        io_uring_queue_exit(&res->ring);
        enif_release_resource(res);
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "enomem"));
    }
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM
nif_prep(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 3) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    ERL_NIF_TERM tag     = argv[1];
    ERL_NIF_TERM op_term = argv[2];

    int op_arity;
    const ERL_NIF_TERM *op;
    if (!enif_get_tuple(env, op_term, &op_arity, &op) || op_arity < 2)
        return enif_make_badarg(env);

    char op_name[32];
    if (!enif_get_atom(env, op[0], op_name, sizeof(op_name), ERL_NIF_LATIN1))
        return enif_make_badarg(env);

    enif_mutex_lock(ring_res->sq_lock);

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring_res->ring);
    if (!sqe) {
        enif_mutex_unlock(ring_res->sq_lock);
        return enif_make_tuple2(env, atom_error, atom_full);
    }

    sqe_ctx_t *ctx = ctx_alloc(env, tag);
    if (!ctx) {
        io_uring_prep_nop(sqe);
        io_uring_sqe_set_data(sqe, NULL);
        enif_mutex_unlock(ring_res->sq_lock);
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "enomem"));
    }

    if (strcmp(op_name, "read") == 0) {
        if (op_arity != 4) goto badarg;
        int fd; unsigned size; ErlNifSInt64 offset;
        if (!enif_get_int(env, op[1], &fd))       goto badarg;
        if (!enif_get_uint(env, op[2], &size))    goto badarg;
        if (!enif_get_int64(env, op[3], &offset)) goto badarg;

        ctx->recv_buf = enif_alloc(sizeof(ErlNifBinary));
        if (!enif_alloc_binary(size, ctx->recv_buf)) goto badarg;
        io_uring_prep_read(sqe, fd, ctx->recv_buf->data, size, (uint64_t)offset);

    } else if (strcmp(op_name, "write") == 0) {
        if (op_arity != 4) goto badarg;
        int fd; ErlNifBinary data; ErlNifSInt64 offset;
        if (!enif_get_int(env, op[1], &fd))          goto badarg;
        if (!enif_inspect_binary(env, op[2], &data)) goto badarg;
        if (!enif_get_int64(env, op[3], &offset))    goto badarg;

        ctx->aux_buf = enif_alloc(data.size);
        memcpy(ctx->aux_buf, data.data, data.size);
        io_uring_prep_write(sqe, fd, ctx->aux_buf, data.size, (uint64_t)offset);

    } else if (strcmp(op_name, "send") == 0) {
        if (op_arity != 3) goto badarg;
        int fd; ErlNifBinary data;
        if (!enif_get_int(env, op[1], &fd))          goto badarg;
        if (!enif_inspect_binary(env, op[2], &data)) goto badarg;

        ctx->aux_buf = enif_alloc(data.size);
        memcpy(ctx->aux_buf, data.data, data.size);
        io_uring_prep_send(sqe, fd, ctx->aux_buf, data.size, 0);

    } else if (strcmp(op_name, "recv") == 0) {
        if (op_arity != 3) goto badarg;
        int fd; unsigned size;
        if (!enif_get_int(env, op[1], &fd))    goto badarg;
        if (!enif_get_uint(env, op[2], &size)) goto badarg;

        ctx->recv_buf = enif_alloc(sizeof(ErlNifBinary));
        if (!enif_alloc_binary(size, ctx->recv_buf)) goto badarg;
        io_uring_prep_recv(sqe, fd, ctx->recv_buf->data, size, 0);

    } else if (strcmp(op_name, "connect") == 0) {
        if (op_arity != 3) goto badarg;
        int fd;
        if (!enif_get_int(env, op[1], &fd)) goto badarg;

        int addr_arity;
        const ERL_NIF_TERM *addr_pair;
        if (!enif_get_tuple(env, op[2], &addr_arity, &addr_pair) || addr_arity != 2)
            goto badarg;

        int ip_arity;
        const ERL_NIF_TERM *ip;
        unsigned a, b, c, d, port;
        if (!enif_get_tuple(env, addr_pair[0], &ip_arity, &ip) || ip_arity != 4)
            goto badarg;
        if (!enif_get_uint(env, ip[0], &a) || !enif_get_uint(env, ip[1], &b) ||
            !enif_get_uint(env, ip[2], &c) || !enif_get_uint(env, ip[3], &d))
            goto badarg;
        if (!enif_get_uint(env, addr_pair[1], &port)) goto badarg;

        struct sockaddr_in *addr = enif_alloc(sizeof(*addr));
        memset(addr, 0, sizeof(*addr));
        addr->sin_family      = AF_INET;
        addr->sin_port        = htons((uint16_t)port);
        addr->sin_addr.s_addr = htonl((a<<24)|(b<<16)|(c<<8)|d);
        ctx->aux_buf = addr;
        io_uring_prep_connect(sqe, fd, (struct sockaddr *)addr, sizeof(*addr));

    } else if (strcmp(op_name, "accept") == 0) {
        if (op_arity != 2) goto badarg;
        int fd;
        if (!enif_get_int(env, op[1], &fd)) goto badarg;
        io_uring_prep_accept(sqe, fd, NULL, NULL, 0);

    } else if (strcmp(op_name, "close") == 0) {
        if (op_arity != 2) goto badarg;
        int fd;
        if (!enif_get_int(env, op[1], &fd)) goto badarg;
        io_uring_prep_close(sqe, fd);

    } else if (strcmp(op_name, "read_fixed") == 0) {
        if (op_arity != 5) goto badarg;
        int fd; unsigned size; ErlNifSInt64 offset; int buf_idx;
        if (!enif_get_int(env, op[1], &fd))       goto badarg;
        if (!enif_get_uint(env, op[2], &size))    goto badarg;
        if (!enif_get_int64(env, op[3], &offset)) goto badarg;
        if (!enif_get_int(env, op[4], &buf_idx))  goto badarg;
        if (buf_idx < 0 || buf_idx >= ring_res->reg_buf_count) goto badarg;

        ctx->fixed_buf_idx = buf_idx;
        io_uring_prep_read_fixed(sqe, fd, ring_res->reg_buf_data[buf_idx],
                                 size, (uint64_t)offset, buf_idx);

    } else if (strcmp(op_name, "write_fixed") == 0) {
        if (op_arity != 5) goto badarg;
        int fd; unsigned size; ErlNifSInt64 offset; int buf_idx;
        if (!enif_get_int(env, op[1], &fd))       goto badarg;
        if (!enif_get_int64(env, op[2], &offset)) goto badarg;
        if (!enif_get_uint(env, op[3], &size))    goto badarg;
        if (!enif_get_int(env, op[4], &buf_idx))  goto badarg;
        if (buf_idx < 0 || buf_idx >= ring_res->reg_buf_count) goto badarg;

        io_uring_prep_write_fixed(sqe, fd, ring_res->reg_buf_data[buf_idx],
                                  size, (uint64_t)offset, buf_idx);

    } else if (strcmp(op_name, "read_file") == 0) {
        if (op_arity != 4) goto badarg;
        int reg_idx; unsigned size; ErlNifSInt64 offset;
        if (!enif_get_int(env, op[1], &reg_idx))  goto badarg;
        if (!enif_get_uint(env, op[2], &size))    goto badarg;
        if (!enif_get_int64(env, op[3], &offset)) goto badarg;

        ctx->recv_buf = enif_alloc(sizeof(ErlNifBinary));
        if (!enif_alloc_binary(size, ctx->recv_buf)) goto badarg;
        io_uring_prep_read(sqe, reg_idx, ctx->recv_buf->data, size, (uint64_t)offset);
        sqe->flags |= IOSQE_FIXED_FILE;

    } else if (strcmp(op_name, "write_file") == 0) {
        if (op_arity != 4) goto badarg;
        int reg_idx; ErlNifBinary data; ErlNifSInt64 offset;
        if (!enif_get_int(env, op[1], &reg_idx))      goto badarg;
        if (!enif_inspect_binary(env, op[2], &data))  goto badarg;
        if (!enif_get_int64(env, op[3], &offset))     goto badarg;

        ctx->aux_buf = enif_alloc(data.size);
        memcpy(ctx->aux_buf, data.data, data.size);
        io_uring_prep_write(sqe, reg_idx, ctx->aux_buf, data.size, (uint64_t)offset);
        sqe->flags |= IOSQE_FIXED_FILE;

    } else {
        sqe_ctx_free(ctx);
        io_uring_prep_nop(sqe);
        io_uring_sqe_set_data(sqe, NULL);
        enif_mutex_unlock(ring_res->sq_lock);
        return enif_make_tuple2(env, atom_error, atom_unknown_op);
    }

    io_uring_sqe_set_data(sqe, ctx);
    enif_mutex_unlock(ring_res->sq_lock);
    return atom_ok;

badarg:
    sqe_ctx_free(ctx);
    io_uring_prep_nop(sqe);
    io_uring_sqe_set_data(sqe, NULL);
    enif_mutex_unlock(ring_res->sq_lock);
    return enif_make_badarg(env);
}


static ERL_NIF_TERM
nif_submit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    enif_mutex_lock(ring_res->sq_lock);
    int submitted = io_uring_submit(&ring_res->ring);
    enif_mutex_unlock(ring_res->sq_lock);
    if (submitted < 0)
        return enif_make_tuple2(env, atom_error, enif_make_int(env, -submitted));

    return enif_make_tuple2(env, atom_ok, enif_make_int(env, submitted));
}


static ERL_NIF_TERM
nif_wait_cqe(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    struct io_uring_cqe *cqe = NULL;
    enif_mutex_lock(ring_res->cq_lock);
    int rc = io_uring_wait_cqe(&ring_res->ring, &cqe);
    enif_mutex_unlock(ring_res->cq_lock);
    if (rc < 0)
        return enif_make_tuple2(env, atom_error, enif_make_int(env, -rc));

    cqe_res_t *res = enif_alloc_resource(CQE_RES_TYPE, sizeof(cqe_res_t));
    if (!res)
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "enomem"));

    res->cqe      = cqe;
    res->ctx      = (sqe_ctx_t *)io_uring_cqe_get_data(cqe);
    res->ring_res = ring_res;
    enif_keep_resource(ring_res);

    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM
nif_wait_n_cqes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;
    unsigned    n;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);
    if (!enif_get_uint(env, argv[1], &n))
        return enif_make_badarg(env);
    if (n == 0)
        return enif_make_tuple2(env, atom_ok, enif_make_list(env, 0));
    if (n > 512)   
        return enif_make_badarg(env);

    struct io_uring_cqe *cqes[512];
    enif_mutex_lock(ring_res->cq_lock);

    {
        struct io_uring_cqe *dummy = NULL;
        int rc = io_uring_wait_cqe_nr(&ring_res->ring, &dummy, n);
        if (rc < 0) {
            enif_mutex_unlock(ring_res->cq_lock);
            return enif_make_tuple2(env, atom_error, enif_make_int(env, -rc));
        }
        (void)dummy;
    }


    unsigned collected = io_uring_peek_batch_cqe(&ring_res->ring, cqes, n);
    if (collected < n) {
        io_uring_cq_advance(&ring_res->ring, collected);
        enif_mutex_unlock(ring_res->cq_lock);
        for (unsigned i = 0; i < collected; i++)
            sqe_ctx_free((sqe_ctx_t *)io_uring_cqe_get_data(cqes[i]));
        return enif_make_tuple2(env, atom_error, enif_make_int(env, EAGAIN));
    }

    ERL_NIF_TERM list = enif_make_list(env, 0);
    unsigned advance_count = 0;

    for (int i = (int)n - 1; i >= 0; i--) {
        struct io_uring_cqe *cqe = cqes[i];
        sqe_ctx_t *ctx = (sqe_ctx_t *)io_uring_cqe_get_data(cqe);

        ERL_NIF_TERM tag_term = ctx
            ? enif_make_copy(env, ctx->tag)
            : atom_undefined;

        ERL_NIF_TERM res_term = enif_make_int(env, cqe->res);

        ERL_NIF_TERM data_term;
        if (!ctx || cqe->res < 0) {
            data_term = atom_undefined;
        } else if (ctx->fixed_buf_idx >= 0) {
            int idx = ctx->fixed_buf_idx;
            size_t nb = (size_t)cqe->res;
            ERL_NIF_TERM bt;
            unsigned char *out = enif_make_new_binary(env, nb, &bt);
            memcpy(out, ring_res->reg_buf_data[idx], nb);
            data_term = enif_make_tuple2(env, atom_ok, bt);
        } else if (ctx->recv_buf) {
            size_t nb = (size_t)cqe->res;
            ERL_NIF_TERM bt;
            unsigned char *out = enif_make_new_binary(env, nb, &bt);
            memcpy(out, ctx->recv_buf->data, nb);
            data_term = enif_make_tuple2(env, atom_ok, bt);
        } else {
            data_term = atom_undefined;  
        }

        list = enif_make_list_cell(env,
            enif_make_tuple3(env, tag_term, res_term, data_term),
            list);

        sqe_ctx_free(ctx);
        advance_count += io_uring_cqe_nr(cqe);
    }

    io_uring_cq_advance(&ring_res->ring, advance_count);
    enif_mutex_unlock(ring_res->cq_lock);

    return enif_make_tuple2(env, atom_ok, list);
}


static ERL_NIF_TERM
nif_cqe_tag(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    cqe_res_t *cqe_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], CQE_RES_TYPE, (void **)&cqe_res))
        return enif_make_badarg(env);
    if (!cqe_res->ctx)
        return atom_undefined;

    return enif_make_copy(env, cqe_res->ctx->tag);
}


static ERL_NIF_TERM
nif_cqe_res(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    cqe_res_t *cqe_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], CQE_RES_TYPE, (void **)&cqe_res))
        return enif_make_badarg(env);
    if (!cqe_res->cqe)
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "cqe_consumed"));

    return enif_make_int(env, cqe_res->cqe->res);
}

static ERL_NIF_TERM
nif_cqe_data(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    cqe_res_t *cqe_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], CQE_RES_TYPE, (void **)&cqe_res))
        return enif_make_badarg(env);
    if (!cqe_res->ctx)
        return atom_undefined;

    int bytes = cqe_res->cqe->res;
    if (bytes < 0)
        return enif_make_tuple2(env, atom_error, enif_make_int(env, -bytes));

    ERL_NIF_TERM bin_term;
    unsigned char *out;

    if (cqe_res->ctx->fixed_buf_idx >= 0) {
        int idx = cqe_res->ctx->fixed_buf_idx;
        out = enif_make_new_binary(env, (size_t)bytes, &bin_term);
        memcpy(out, cqe_res->ring_res->reg_buf_data[idx], (size_t)bytes);
        return enif_make_tuple2(env, atom_ok, bin_term);
    }

    if (!cqe_res->ctx->recv_buf)
        return atom_undefined;

    out = enif_make_new_binary(env, (size_t)bytes, &bin_term);
    memcpy(out, cqe_res->ctx->recv_buf->data, (size_t)bytes);
    return enif_make_tuple2(env, atom_ok, bin_term);
}


static ERL_NIF_TERM
nif_cqe_seen(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;
    cqe_res_t  *cqe_res;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[1], CQE_RES_TYPE, (void **)&cqe_res))
        return enif_make_badarg(env);

    if (cqe_res->cqe) {
        enif_mutex_lock(ring_res->cq_lock);
        io_uring_cqe_seen(&ring_res->ring, cqe_res->cqe);
        enif_mutex_unlock(ring_res->cq_lock);
        cqe_res->cqe = NULL;
        sqe_ctx_free(cqe_res->ctx);
        cqe_res->ctx = NULL;
    }

    return atom_ok;
}


static ERL_NIF_TERM
nif_teardown(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    if (ring_res->initialised) {
        io_uring_queue_exit(&ring_res->ring);
        ring_res->initialised = 0;
    }

    return atom_ok;
}


static ERL_NIF_TERM
nif_sys_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char path[4096];
    int  oflags, mode;

    if (argc != 3) return enif_make_badarg(env);

    if (!enif_get_string(env, argv[0], path, sizeof(path), ERL_NIF_LATIN1)) {
        /* Try binary */
        ErlNifBinary bin;
        if (!enif_inspect_binary(env, argv[0], &bin) || bin.size >= sizeof(path))
            return enif_make_badarg(env);
        memcpy(path, bin.data, bin.size);
        path[bin.size] = '\0';
    }

    if (!enif_get_int(env, argv[1], &oflags)) return enif_make_badarg(env);
    if (!enif_get_int(env, argv[2], &mode))   return enif_make_badarg(env);

    int fd = open(path, oflags, (mode_t)mode);
    if (fd < 0)
        return enif_make_tuple2(env, atom_error, enif_make_int(env, errno));

    return enif_make_tuple2(env, atom_ok, enif_make_int(env, fd));
}


static ERL_NIF_TERM
nif_register_buffers(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    unsigned count;
    if (!enif_get_list_length(env, argv[1], &count) || count == 0)
        return enif_make_badarg(env);

    struct iovec *iovecs    = enif_alloc(count * sizeof(struct iovec));
    void        **buf_data  = enif_alloc(count * sizeof(void *));
    if (!iovecs || !buf_data) {
        enif_free(iovecs); enif_free(buf_data);
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "enomem"));
    }
    memset(buf_data, 0, count * sizeof(void *));

    ERL_NIF_TERM list = argv[1];
    ERL_NIF_TERM head;
    unsigned i = 0;
    while (enif_get_list_cell(env, list, &head, &list)) {
        ErlNifBinary bin;
        if (!enif_inspect_binary(env, head, &bin)) {
            for (unsigned j = 0; j < i; j++) enif_free(buf_data[j]);
            enif_free(iovecs); enif_free(buf_data);
            return enif_make_badarg(env);
        }
        buf_data[i] = enif_alloc(bin.size);
        memcpy(buf_data[i], bin.data, bin.size);
        iovecs[i].iov_base = buf_data[i];
        iovecs[i].iov_len  = bin.size;
        i++;
    }

    enif_mutex_lock(ring_res->sq_lock);
    int rc = io_uring_register_buffers(&ring_res->ring, iovecs, count);
    if (rc < 0) {
        enif_mutex_unlock(ring_res->sq_lock);
        for (unsigned j = 0; j < count; j++) enif_free(buf_data[j]);
        enif_free(iovecs); enif_free(buf_data);
        return enif_make_tuple2(env, atom_error, enif_make_int(env, -rc));
    }
    ring_res->reg_bufs      = iovecs;
    ring_res->reg_buf_data  = buf_data;
    ring_res->reg_buf_count = (int)count;
    enif_mutex_unlock(ring_res->sq_lock);

    return atom_ok;
}

static ERL_NIF_TERM
nif_unregister_buffers(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    enif_mutex_lock(ring_res->sq_lock);
    io_uring_unregister_buffers(&ring_res->ring);
    if (ring_res->reg_buf_data) {
        for (int i = 0; i < ring_res->reg_buf_count; i++)
            enif_free(ring_res->reg_buf_data[i]);
        enif_free(ring_res->reg_buf_data);
        ring_res->reg_buf_data = NULL;
    }
    if (ring_res->reg_bufs) { enif_free(ring_res->reg_bufs); ring_res->reg_bufs = NULL; }
    ring_res->reg_buf_count = 0;
    enif_mutex_unlock(ring_res->sq_lock);

    return atom_ok;
}

static ERL_NIF_TERM
nif_register_files(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    unsigned count;
    if (!enif_get_list_length(env, argv[1], &count) || count == 0)
        return enif_make_badarg(env);

    int *fds = enif_alloc(count * sizeof(int));
    if (!fds)
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "enomem"));

    ERL_NIF_TERM list = argv[1];
    ERL_NIF_TERM head;
    unsigned i = 0;
    while (enif_get_list_cell(env, list, &head, &list)) {
        if (!enif_get_int(env, head, &fds[i])) {
            enif_free(fds);
            return enif_make_badarg(env);
        }
        i++;
    }

    enif_mutex_lock(ring_res->sq_lock);
    int rc = io_uring_register_files(&ring_res->ring, fds, count);
    if (rc < 0) {
        enif_mutex_unlock(ring_res->sq_lock);
        enif_free(fds);
        return enif_make_tuple2(env, atom_error, enif_make_int(env, -rc));
    }
    ring_res->reg_fds      = fds;
    ring_res->reg_fd_count = (int)count;
    enif_mutex_unlock(ring_res->sq_lock);

    return atom_ok;
}

static ERL_NIF_TERM
nif_unregister_files(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ring_res_t *ring_res;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], RING_RES_TYPE, (void **)&ring_res))
        return enif_make_badarg(env);

    enif_mutex_lock(ring_res->sq_lock);
    io_uring_unregister_files(&ring_res->ring);
    if (ring_res->reg_fds) { enif_free(ring_res->reg_fds); ring_res->reg_fds = NULL; }
    ring_res->reg_fd_count = 0;
    enif_mutex_unlock(ring_res->sq_lock);

    return atom_ok;
}


static ErlNifFunc nif_funcs[] = {
    {"setup",              2, nif_setup,              0},
    {"sys_open",           3, nif_sys_open,           0},
    {"prep",               3, nif_prep,               0},
    {"submit",             1, nif_submit,             ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"wait_cqe",           1, nif_wait_cqe,           ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"wait_n_cqes",        2, nif_wait_n_cqes,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cqe_tag",            1, nif_cqe_tag,            0},
    {"cqe_res",            1, nif_cqe_res,            0},
    {"cqe_data",           1, nif_cqe_data,           0},
    {"cqe_seen",           2, nif_cqe_seen,           0},
    {"teardown",           1, nif_teardown,           0},
    {"register_buffers",   2, nif_register_buffers,   0},
    {"unregister_buffers", 1, nif_unregister_buffers, 0},
    {"register_files",     2, nif_register_files,     0},
    {"unregister_files",   1, nif_unregister_files,   0}
};

static int
nif_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)load_info; (void)priv_data;

    atom_ok         = enif_make_atom(env, "ok");
    atom_error      = enif_make_atom(env, "error");
    atom_undefined  = enif_make_atom(env, "undefined");
    atom_full       = enif_make_atom(env, "full");
    atom_unknown_op = enif_make_atom(env, "unknown_op");

    RING_RES_TYPE = enif_open_resource_type(env, NULL, "io_uring_ring",
        ring_destructor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (!RING_RES_TYPE) return -1;

    CQE_RES_TYPE = enif_open_resource_type(env, NULL, "io_uring_cqe",
        cqe_destructor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (!CQE_RES_TYPE) return -1;

    return 0;
}

static void
nif_unload(ErlNifEnv *env, void *priv_data) { (void)env; (void)priv_data; }

ERL_NIF_INIT(io_uring, nif_funcs, nif_load, NULL, NULL, nif_unload)
