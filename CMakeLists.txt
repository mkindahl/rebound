cmake_minimum_required(VERSION 3.10)
project(rebound VERSION 1.0.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_compile_options(-Wall -Wextra -Werror -pedantic)

include(CheckIncludeFile)

check_include_file(errno.h HAVE_ERRNO_H)
check_include_file(getopt.h HAVE_GETOPT_H)
check_include_file(signal.h HAVE_SIGNAL_H)
check_include_file(sys/wait.h HAVE_SYS_WAIT_H)
check_include_file(time.h HAVE_TIME_H)
check_include_file(unistd.h HAVE_UNISTD_H)

set(_REQUIRED_HEADERS
  HAVE_ERRNO_H
  HAVE_GETOPT_H
  HAVE_SIGNAL_H
  HAVE_SYS_WAIT_H
  HAVE_TIME_H
  HAVE_UNISTD_H
)

foreach(_hdr ${_REQUIRED_HEADERS})
  if(NOT ${_hdr})
    message(FATAL_ERROR "Required header not found: ${_hdr}")
  endif()
endforeach()

# --- Function checks ---

include(CheckSymbolExists)

set(CMAKE_REQUIRED_DEFINITIONS -D_POSIX_C_SOURCE=199309L)

check_symbol_exists(fork unistd.h HAVE_FORK)
check_symbol_exists(execvp unistd.h HAVE_EXECVP)
check_symbol_exists(setpgid unistd.h HAVE_SETPGID)
check_symbol_exists(sigprocmask signal.h HAVE_SIGPROCMASK)
check_symbol_exists(sigtimedwait signal.h HAVE_SIGTIMEDWAIT)
check_symbol_exists(sigfillset signal.h HAVE_SIGFILLSET)
check_symbol_exists(sigaction signal.h HAVE_SIGACTION)
check_symbol_exists(waitpid sys/wait.h HAVE_WAITPID)
check_symbol_exists(clock_gettime time.h HAVE_CLOCK_GETTIME)
check_symbol_exists(nanosleep time.h HAVE_NANOSLEEP)
check_symbol_exists(getopt_long getopt.h HAVE_GETOPT_LONG)

set(_REQUIRED_FUNCTIONS
  HAVE_FORK
  HAVE_EXECVP
  HAVE_SETPGID
  HAVE_SIGPROCMASK
  HAVE_SIGTIMEDWAIT
  HAVE_SIGFILLSET
  HAVE_SIGACTION
  HAVE_WAITPID
  HAVE_CLOCK_GETTIME
  HAVE_NANOSLEEP
  HAVE_GETOPT_LONG
)

foreach(_fn ${_REQUIRED_FUNCTIONS})
  if(NOT ${_fn})
    message(FATAL_ERROR "Required function not found: ${_fn}")
  endif()
endforeach()

# --- Type checks ---

include(CheckTypeSize)

set(CMAKE_EXTRA_INCLUDE_FILES signal.h)
check_type_size(siginfo_t SIGINFO_T)
set(CMAKE_EXTRA_INCLUDE_FILES sys/types.h)
check_type_size(pid_t PID_T)
set(CMAKE_EXTRA_INCLUDE_FILES)

if(NOT HAVE_SIGINFO_T)
  message(FATAL_ERROR "Required type not found: siginfo_t")
endif()
if(NOT HAVE_PID_T)
  message(FATAL_ERROR "Required type not found: pid_t")
endif()

add_executable(rebound rebound.c)

enable_testing()

find_program(PROVE prove)
find_program(PERL perl)

if(PROVE AND PERL)
  file(GLOB TEST_FILES "${CMAKE_SOURCE_DIR}/t/*.t")

  foreach(_test ${TEST_FILES})
    get_filename_component(_name ${_test} NAME_WE)
    add_test(
      NAME ${_name}
      COMMAND ${PROVE} -v ${_test}
      WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    )
    set_tests_properties(${_name} PROPERTIES
      ENVIRONMENT "REBOUND=$<TARGET_FILE:rebound>"
    )
  endforeach()
else()
  message(WARNING "prove or perl not found -- tests will not be available (install perl)")
endif()

# --- Documentation ---

find_program(NATURALDOCS naturaldocs)

if(NATURALDOCS)
  set(DOC_OUTPUT_DIR "${CMAKE_BINARY_DIR}/docs")
  set(DOC_PROJECT_DIR "${CMAKE_SOURCE_DIR}/nd")

  add_custom_target(docs
    COMMAND ${NATURALDOCS} -i "${CMAKE_SOURCE_DIR}" -o html "${DOC_OUTPUT_DIR}" -p "${DOC_PROJECT_DIR}"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Generating reference documentation with NaturalDocs"
    VERBATIM
  )
else()
  add_custom_target(docs
    COMMAND ${CMAKE_COMMAND} -E echo "naturaldocs not found -- install it to generate documentation"
    COMMAND ${CMAKE_COMMAND} -E false
  )
endif()

install(TARGETS rebound DESTINATION bin)

option(BUILD_STATIC "Build a statically linked binary (uses current compiler)" OFF)
option(BUILD_MUSL_STATIC "Build a static binary with musl-gcc (for minimal Docker images)" OFF)

if(BUILD_MUSL_STATIC)
  find_program(MUSL_GCC musl-gcc)
  if(NOT MUSL_GCC)
    message(FATAL_ERROR "musl-gcc not found (install musl-tools)")
  endif()
  set(CMAKE_C_COMPILER ${MUSL_GCC})
  target_link_options(rebound PRIVATE -static)
elseif(BUILD_STATIC)
  target_link_options(rebound PRIVATE -static)
endif()
