cmake_minimum_required(VERSION 3.22)

project(pg_bigm_windows LANGUAGES C)

if(NOT WIN32)
    message(FATAL_ERROR "This build configuration supports Windows only.")
endif()

set(PGROOT "" CACHE PATH "PostgreSQL installation root")
set(UPSTREAM_DIR "" CACHE PATH "Path to the checked-out pg_bigm upstream source")

if(NOT EXISTS "${PGROOT}/include/server/postgres.h")
    message(FATAL_ERROR "PostgreSQL server headers were not found under PGROOT: ${PGROOT}")
endif()

if(NOT EXISTS "${PGROOT}/lib/postgres.lib")
    message(FATAL_ERROR "postgres.lib was not found under PGROOT: ${PGROOT}")
endif()

if(NOT EXISTS "${UPSTREAM_DIR}/bigm_op.c" OR NOT EXISTS "${UPSTREAM_DIR}/bigm_gin.c")
    message(FATAL_ERROR "pg_bigm upstream sources were not found under UPSTREAM_DIR: ${UPSTREAM_DIR}")
endif()

add_library(pg_bigm SHARED
    "${UPSTREAM_DIR}/bigm_op.c"
    "${UPSTREAM_DIR}/bigm_gin.c"
)

target_include_directories(pg_bigm PRIVATE
    "${UPSTREAM_DIR}"
    "${PGROOT}/include/server/port/win32_msvc"
    "${PGROOT}/include/server/port/win32"
    "${PGROOT}/include/server"
    "${PGROOT}/include"
)

target_link_libraries(pg_bigm PRIVATE
    "${PGROOT}/lib/postgres.lib"
)

target_compile_definitions(pg_bigm PRIVATE
    WIN32
    _CRT_SECURE_NO_WARNINGS
)

set_target_properties(pg_bigm PROPERTIES
    PREFIX ""
    OUTPUT_NAME "pg_bigm"
)

if(MSVC)
    set_property(
        TARGET pg_bigm
        PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL$<$<CONFIG:Debug>:Debug>"
    )
    target_compile_options(pg_bigm PRIVATE /W3)
endif()
