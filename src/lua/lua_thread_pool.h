#ifndef LUA_THREAD_POOL_H_
#define LUA_THREAD_POOL_H_

#include <lua.h>

struct thread_entry {
	lua_State *lua_state;
	gint thread_index;
	gpointer cd;
};

struct thread_pool;

/**
 * Allocates new thread pool on state L. Pre-creates number of lua-threads to use later on
 *
 * @param L
 * @return
 */
struct lua_thread_pool *
lua_thread_pool_new (lua_State * L);

/**
 * Destroys the pool
 * @param pool
 */
void
lua_thread_pool_free (struct lua_thread_pool *pool);

/**
 * Extracts a thread from the list of available ones.
 * It immediately becames running one and should be used to run a Lua script/function straight away.
 * as soon as the code is finished, it should be either returned into list of available threads by
 * calling lua_thread_pool_return() or terminated by calling lua_thread_pool_terminate_entry()
 * if the code finished with error.
 *
 * If the code performed YIELD, the thread is still running and it's live should be controlled by the callee
 *
 * @param pool
 * @return
 */
struct thread_entry *
lua_thread_pool_get(struct lua_thread_pool *pool);

/**
 * Return thread into the list of available ones. It can't be done with yielded or dead threads.
 *
 * @param pool
 * @param thread_entry
 */
void
lua_thread_pool_return(struct lua_thread_pool *pool, struct thread_entry *thread_entry);

/**
 * Removes thread from Lua state. It should be done to dead (which ended with an error) threads only
 *
 * @param pool
 * @param thread_entry
 */
void
lua_thread_pool_terminate_entry(struct lua_thread_pool *pool, struct thread_entry *thread_entry);

/**
 * Currently running thread. Typically needed in yielding point - to fill-up continuation.
 *
 * @param pool
 * @return
 */
struct thread_entry *
lua_thread_pool_get_running_entry(struct lua_thread_pool *pool);

/**
 * Updates currently running thread
 *
 * @param pool
 * @param thread_entry
 */
void
lua_thread_pool_set_running_entry(struct lua_thread_pool *pool, struct thread_entry *thread_entry);

#endif /* LUA_THREAD_POOL_H_ */
