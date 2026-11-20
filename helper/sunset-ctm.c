// Per-monitor color temperature for Hyprland.
//
// hyprsunset applies one matrix to every output, and Hyprland allows only one
// CTM client. This process is that client. It keeps a temperature per output
// and answers the hyprsunset socket, so `hyprctl hyprsunset` and Omarchy's
// night-light shortcut keep working. A global temperature or identity applies
// to every output. `output <name> temperature <K>` and `output <name> identity`
// change one output.
//
// On exit the compositor clears the matrices.

#define _GNU_SOURCE

#include "ctm-client.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>

#define MAX_OUTPUTS 16
#define MAX_DESIRED 32
#define REPLY_MAX 4096

struct desired {
    char name[64];
    unsigned kelvin;
    int identity;
    int used;
};

struct output {
    struct wl_output *wl;
    uint32_t global_id;
    char name[64];
    int named;
    int used;
};

struct app {
    struct wl_display *display;
    struct wl_registry *registry;
    struct hyprland_ctm_control_manager_v1 *ctm;
    struct output outputs[MAX_OUTPUTS];
    struct desired desired[MAX_DESIRED];
    int server;
    int ready;
    int blocked;
    int quit;
    unsigned global_kelvin;
    double gamma;
    int have_foreign;
    unsigned foreign_kelvin;
    int foreign_identity;
};

static struct app state;
static char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static char state_path[512];
static volatile sig_atomic_t stop_requested;

static void apply_all(void);

static double clampd(double value, double lo, double hi) {
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

static unsigned clamp_kelvin(long long value) {
    if (value < 1000) return 1000;
    if (value > 20000) return 20000;
    return (unsigned)value;
}

// Same curve hyprsunset uses (Tanner Helland). Row-major, diagonal RGB.
static void matrix_for_kelvin(unsigned kelvin, double gamma, double out[9]) {
    double r = 1.0, g = 1.0, b = 1.0;
    unsigned temp = kelvin / 100;

    if (temp <= 66) {
        r = 255.0;
        g = clampd(99.4708025861 * log((double)temp) - 161.1195681661, 0.0, 255.0);
        if (temp <= 19) b = 0.0;
        else b = clampd(log((double)temp - 10.0) * 138.5177312231 - 305.0447927307, 0.0, 255.0);
    } else {
        r = clampd(329.698727446 * pow((double)temp - 60.0, -0.1332047592), 0.0, 255.0);
        g = clampd(288.1221695283 * pow((double)temp - 60.0, -0.0755148492), 0.0, 255.0);
        b = 255.0;
    }

    memset(out, 0, 9 * sizeof(double));
    out[0] = (r / 255.0) * gamma;
    out[4] = (g / 255.0) * gamma;
    out[8] = (b / 255.0) * gamma;
}

static int valid_name(const char *name) {
    size_t n;
    size_t i;
    if (!name) return 0;
    n = strlen(name);
    if (n < 1 || n > 63) return 0;
    if (name[0] == '-' || name[0] == '.') return 0;
    for (i = 0; i < n; i++) {
        char c = name[i];
        if (!isalnum((unsigned char)c) && c != '_' && c != '.' && c != '-') return 0;
    }
    return 1;
}

static void runtime_paths(void) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *sig = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (!runtime || !runtime[0]) runtime = "/tmp";
    snprintf(state_path, sizeof state_path, "%s/omarchy-sunset-ctm.state", runtime);
    socket_path[0] = '\0';
    if (sig && sig[0]) {
        int wrote = snprintf(socket_path, sizeof socket_path, "%s/hypr/%s/.hyprsunset.sock", runtime, sig);
        if (wrote < 0 || (size_t)wrote >= sizeof socket_path) socket_path[0] = '\0';
    }
}

static struct desired *find_desired(const char *name, int create) {
    int i;
    int free_slot = -1;
    for (i = 0; i < MAX_DESIRED; i++) {
        if (state.desired[i].used && strcmp(state.desired[i].name, name) == 0) return &state.desired[i];
        if (!state.desired[i].used && free_slot < 0) free_slot = i;
    }
    if (!create || free_slot < 0) return NULL;
    memset(&state.desired[free_slot], 0, sizeof state.desired[free_slot]);
    snprintf(state.desired[free_slot].name, sizeof state.desired[free_slot].name, "%s", name);
    state.desired[free_slot].kelvin = state.global_kelvin ? state.global_kelvin : 4000;
    state.desired[free_slot].identity = 1;
    state.desired[free_slot].used = 1;
    return &state.desired[free_slot];
}

static struct output *find_output(const char *name) {
    int i;
    for (i = 0; i < MAX_OUTPUTS; i++) {
        if (state.outputs[i].used && state.outputs[i].named && strcmp(state.outputs[i].name, name) == 0)
            return &state.outputs[i];
    }
    return NULL;
}

static void save_state(void) {
    char tmp[sizeof state_path + 8];
    FILE *file;
    int i;
    if (!state_path[0]) return;
    snprintf(tmp, sizeof tmp, "%s.tmp", state_path);
    file = fopen(tmp, "w");
    if (!file) return;
    fprintf(file, "gamma %.6f\n", state.gamma);
    fprintf(file, "global %u\n", state.global_kelvin);
    for (i = 0; i < MAX_DESIRED; i++) {
        if (!state.desired[i].used) continue;
        fprintf(file, "output %s %u %d\n", state.desired[i].name, state.desired[i].kelvin, state.desired[i].identity ? 1 : 0);
    }
    if (fclose(file) == 0) rename(tmp, state_path);
}

static void load_state(void) {
    FILE *file = fopen(state_path, "r");
    char line[256];
    if (!file) return;
    while (fgets(line, sizeof line, file)) {
        char name[64];
        unsigned kelvin = 0;
        int identity = 1;
        double gamma = 1.0;
        unsigned global = 0;
        if (sscanf(line, "gamma %lf", &gamma) == 1) {
            if (gamma < 0) gamma = 0;
            if (gamma > 2) gamma = 2;
            state.gamma = gamma;
        } else if (sscanf(line, "global %u", &global) == 1) {
            state.global_kelvin = clamp_kelvin(global);
        } else if (sscanf(line, "output %63s %u %d", name, &kelvin, &identity) == 3 && valid_name(name)) {
            struct desired *desired = find_desired(name, 1);
            if (!desired) continue;
            desired->kelvin = clamp_kelvin(kelvin);
            desired->identity = identity ? 1 : 0;
        }
    }
    fclose(file);
}

static void apply_all(void) {
    int i;
    if (!state.ctm || state.blocked || !state.ready) return;
    for (i = 0; i < MAX_OUTPUTS; i++) {
        struct output *output = &state.outputs[i];
        struct desired *desired;
        double matrix[9];
        double gamma = state.gamma;
        if (!output->used || !output->wl) continue;
        if (output->named) desired = find_desired(output->name, 1);
        else desired = NULL;
        if (!desired || desired->identity) {
            memset(matrix, 0, sizeof matrix);
            matrix[0] = gamma;
            matrix[4] = gamma;
            matrix[8] = gamma;
        } else {
            matrix_for_kelvin(desired->kelvin, gamma, matrix);
        }
        hyprland_ctm_control_manager_v1_set_ctm_for_output(
            state.ctm, output->wl,
            wl_fixed_from_double(matrix[0]), wl_fixed_from_double(matrix[1]), wl_fixed_from_double(matrix[2]),
            wl_fixed_from_double(matrix[3]), wl_fixed_from_double(matrix[4]), wl_fixed_from_double(matrix[5]),
            wl_fixed_from_double(matrix[6]), wl_fixed_from_double(matrix[7]), wl_fixed_from_double(matrix[8]));
    }
    hyprland_ctm_control_manager_v1_commit(state.ctm);
    wl_display_flush(state.display);
    save_state();
}

static void each_desired(void (*fn)(struct desired *desired, void *data), void *data) {
    int i;
    for (i = 0; i < MAX_OUTPUTS; i++) {
        if (state.outputs[i].used && state.outputs[i].named) find_desired(state.outputs[i].name, 1);
    }
    for (i = 0; i < MAX_DESIRED; i++) {
        if (state.desired[i].used) fn(&state.desired[i], data);
    }
}

static void assign_temperature(struct desired *desired, void *data) {
    desired->kelvin = *(unsigned *)data;
    desired->identity = 0;
}

static void assign_identity(struct desired *desired, void *data) {
    desired->identity = *(int *)data;
}

static void set_all_temperature(unsigned kelvin) {
    state.global_kelvin = kelvin;
    each_desired(assign_temperature, &kelvin);
    apply_all();
}

static void set_all_identity(int identity) {
    each_desired(assign_identity, &identity);
    apply_all();
}

static unsigned representative_kelvin(void) {
    int i;
    int any = 0;
    unsigned lowest = 20000;
    for (i = 0; i < MAX_OUTPUTS; i++) {
        struct desired *desired;
        if (!state.outputs[i].used || !state.outputs[i].named) continue;
        desired = find_desired(state.outputs[i].name, 0);
        if (!desired || desired->identity) continue;
        any = 1;
        if (desired->kelvin < lowest) lowest = desired->kelvin;
    }
    return any ? lowest : 6500;
}

static int all_identity(void) {
    int i;
    int any = 0;
    for (i = 0; i < MAX_OUTPUTS; i++) {
        struct desired *desired;
        if (!state.outputs[i].used || !state.outputs[i].named) continue;
        any = 1;
        desired = find_desired(state.outputs[i].name, 0);
        if (desired && !desired->identity) return 0;
    }
    return any ? 1 : 1;
}

static void trim(char *text) {
    size_t n;
    char *start = text;
    while (*start && isspace((unsigned char)*start)) start++;
    if (start != text) memmove(text, start, strlen(start) + 1);
    n = strlen(text);
    while (n > 0 && isspace((unsigned char)text[n - 1])) text[--n] = '\0';
}

static int parse_kelvin_arg(const char *arg, unsigned current, unsigned *out) {
    char *end = NULL;
    long long value;
    if (!arg || !arg[0]) return 0;
    if (arg[0] == '+' || (arg[0] == '-' && arg[1])) {
        long long delta = strtoll(arg, &end, 10);
        if (!end || *end) return 0;
        value = (long long)current + delta;
    } else {
        value = strtoll(arg, &end, 10);
        if (!end || *end) return 0;
    }
    *out = clamp_kelvin(value);
    return 1;
}

static void reply_outputs(char *reply, size_t reply_len) {
    size_t used = 0;
    int i;
    int first = 1;
    int wrote = snprintf(reply, reply_len, "{\"gamma\":%d,\"outputs\":[", (int)lround(state.gamma * 100.0));
    if (wrote < 0) wrote = 0;
    used = (size_t)wrote;
    for (i = 0; i < MAX_OUTPUTS && used < reply_len; i++) {
        struct desired *desired;
        if (!state.outputs[i].used || !state.outputs[i].named) continue;
        desired = find_desired(state.outputs[i].name, 1);
        if (!desired) continue;
        wrote = snprintf(reply + used, reply_len - used, "%s{\"name\":\"%s\",\"kelvin\":%u,\"identity\":%s}",
                         first ? "" : ",", state.outputs[i].name, desired->kelvin, desired->identity ? "true" : "false");
        if (wrote < 0) break;
        used += (size_t)wrote;
        first = 0;
    }
    if (used < reply_len) snprintf(reply + used, reply_len - used, "]}");
}

static void handle_request(char *request, char *reply, size_t reply_len) {
    snprintf(reply, reply_len, "invalid command");
    trim(request);
    if (strcmp(request, "quit") == 0) {
        state.quit = 1;
        snprintf(reply, reply_len, "ok");
        return;
    }
    if (strcmp(request, "outputs") == 0) {
        reply_outputs(reply, reply_len);
        return;
    }
    if (strncmp(request, "output ", 7) == 0) {
        char name[64];
        char action[32];
        char extra[64];
        struct desired *desired;
        extra[0] = '\0';
        if (sscanf(request + 7, "%63s %31s %63s", name, action, extra) < 2 || !valid_name(name)) {
            snprintf(reply, reply_len, "invalid output");
            return;
        }
        if (!find_output(name)) {
            snprintf(reply, reply_len, "unknown output");
            return;
        }
        desired = find_desired(name, 1);
        if (!desired) {
            snprintf(reply, reply_len, "invalid output");
            return;
        }
        if (strcmp(action, "identity") == 0) {
            desired->identity = 1;
            apply_all();
            snprintf(reply, reply_len, "ok");
            return;
        }
        if (strcmp(action, "temperature") == 0) {
            unsigned kelvin = 0;
            if (!extra[0]) {
                snprintf(reply, reply_len, "%u", desired->identity ? 6500 : desired->kelvin);
                return;
            }
            if (!parse_kelvin_arg(extra, desired->kelvin, &kelvin)) {
                snprintf(reply, reply_len, "Invalid temperature (should be an integer in range 1000-20000)");
                return;
            }
            desired->kelvin = kelvin;
            desired->identity = 0;
            apply_all();
            snprintf(reply, reply_len, "ok");
            return;
        }
        snprintf(reply, reply_len, "invalid output");
        return;
    }
    if (strncmp(request, "temperature", 11) == 0 && (request[11] == '\0' || request[11] == ' ')) {
        if (request[11] == '\0') {
            snprintf(reply, reply_len, "%u", representative_kelvin());
            return;
        }
        unsigned kelvin = 0;
        if (!parse_kelvin_arg(request + 12, state.global_kelvin ? state.global_kelvin : representative_kelvin(), &kelvin)) {
            snprintf(reply, reply_len, "Invalid temperature (should be an integer in range 1000-20000)");
            return;
        }
        set_all_temperature(kelvin);
        snprintf(reply, reply_len, "ok");
        return;
    }
    if (strncmp(request, "identity", 8) == 0 && (request[8] == '\0' || request[8] == ' ')) {
        const char *arg = request[8] == '\0' ? "" : request + 9;
        if (strcmp(arg, "get") == 0) {
            snprintf(reply, reply_len, all_identity() ? "true" : "false");
            return;
        }
        if (arg[0] == '\0' || strcmp(arg, "true") == 0) {
            set_all_identity(1);
            snprintf(reply, reply_len, "ok");
            return;
        }
        if (strcmp(arg, "false") == 0) {
            set_all_identity(0);
            snprintf(reply, reply_len, "ok");
            return;
        }
        snprintf(reply, reply_len, "Invalid identity value (should be true or false)");
        return;
    }
    if (strncmp(request, "gamma", 5) == 0 && (request[5] == '\0' || request[5] == ' ')) {
        double percent = state.gamma * 100.0;
        char *end = NULL;
        if (request[5] == '\0') {
            snprintf(reply, reply_len, "%d", (int)lround(percent));
            return;
        }
        if (request[6] == '+' || request[6] == '-') percent += strtod(request + 6, &end);
        else percent = strtod(request + 6, &end);
        if (!end || *end || percent < 0 || percent > 200) {
            snprintf(reply, reply_len, "Invalid gamma value (should be in range 0-200%%)");
            return;
        }
        state.gamma = percent / 100.0;
        apply_all();
        snprintf(reply, reply_len, "ok");
        return;
    }
}

static void on_blocked(void *data, struct hyprland_ctm_control_manager_v1 *manager) {
    (void)data;
    (void)manager;
    state.blocked = 1;
}

static const struct hyprland_ctm_control_manager_v1_listener ctm_listener = {
    .blocked = on_blocked,
};

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y, int32_t w, int32_t h, int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)output; (void)x; (void)y; (void)w; (void)h; (void)subpixel; (void)make; (void)model; (void)transform;
}
static void output_mode(void *data, struct wl_output *output, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    (void)data; (void)output; (void)flags; (void)w; (void)h; (void)refresh;
}
static void output_done(void *data, struct wl_output *output) { (void)data; (void)output; }
static void output_scale(void *data, struct wl_output *output, int32_t factor) { (void)data; (void)output; (void)factor; }
static void output_name(void *data, struct wl_output *output, const char *name) {
    struct output *slot = data;
    (void)output;
    if (!name || !valid_name(name)) return;
    snprintf(slot->name, sizeof slot->name, "%s", name);
    slot->named = 1;
    if (state.have_foreign) {
        struct desired *desired = find_desired(name, 1);
        if (desired) {
            desired->kelvin = state.foreign_kelvin;
            desired->identity = state.foreign_identity;
        }
    }
    if (state.ready) apply_all();
}
static void output_description(void *data, struct wl_output *output, const char *description) {
    (void)data; (void)output; (void)description;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, hyprland_ctm_control_manager_v1_interface.name) == 0) {
        uint32_t ver = version < 2 ? version : 2;
        state.ctm = wl_registry_bind(registry, name, &hyprland_ctm_control_manager_v1_interface, ver);
        if (ver >= 2) hyprland_ctm_control_manager_v1_add_listener(state.ctm, &ctm_listener, NULL);
    } else if (strcmp(interface, wl_output_interface.name) == 0) {
        int i;
        uint32_t ver = version < 4 ? version : 4;
        for (i = 0; i < MAX_OUTPUTS; i++) {
            if (state.outputs[i].used) continue;
            state.outputs[i].used = 1;
            state.outputs[i].global_id = name;
            state.outputs[i].named = 0;
            state.outputs[i].name[0] = '\0';
            state.outputs[i].wl = wl_registry_bind(registry, name, &wl_output_interface, ver);
            wl_output_add_listener(state.outputs[i].wl, &output_listener, &state.outputs[i]);
            break;
        }
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    int i;
    (void)data;
    (void)registry;
    for (i = 0; i < MAX_OUTPUTS; i++) {
        if (!state.outputs[i].used || state.outputs[i].global_id != name) continue;
        if (state.outputs[i].wl) wl_output_destroy(state.outputs[i].wl);
        memset(&state.outputs[i], 0, sizeof state.outputs[i]);
        if (state.ready) apply_all();
        break;
    }
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_remove,
};

static void on_signal(int signo) {
    (void)signo;
    stop_requested = 1;
}

static int connect_wayland(void) {
    state.display = wl_display_connect(NULL);
    if (!state.display) return 0;
    state.registry = wl_display_get_registry(state.display);
    wl_registry_add_listener(state.registry, &registry_listener, NULL);
    wl_display_roundtrip(state.display);
    wl_display_roundtrip(state.display);
    if (state.blocked || !state.ctm) return 0;
    return 1;
}

static int listen_socket(void) {
    struct sockaddr_un address;
    int fd;
    if (!socket_path[0]) return -1;
    unlink(socket_path);
    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof address.sun_path, "%s", socket_path);
    if (bind(fd, (struct sockaddr *)&address, SUN_LEN(&address)) < 0) {
        close(fd);
        return -1;
    }
    chmod(socket_path, 0600);
    if (listen(fd, 8) < 0) {
        close(fd);
        unlink(socket_path);
        return -1;
    }
    return fd;
}

static void serve_client(int fd) {
    char request[1024];
    char reply[REPLY_MAX];
    struct pollfd pfd = {.fd = fd, .events = POLLIN};
    ssize_t n;
    if (poll(&pfd, 1, 500) <= 0) return;
    n = recv(fd, request, sizeof request - 1, 0);
    if (n <= 0) return;
    request[n] = '\0';
    reply[0] = '\0';
    handle_request(request, reply, sizeof reply);
    if (reply[0]) send(fd, reply, strlen(reply), MSG_NOSIGNAL);
}

static void daemon_loop(void) {
    while (!state.quit && !stop_requested) {
        struct pollfd pfds[2];
        int ready;
        if (wl_display_flush(state.display) < 0 && errno != EAGAIN) break;
        while (wl_display_prepare_read(state.display) != 0) wl_display_dispatch_pending(state.display);
        pfds[0].fd = wl_display_get_fd(state.display);
        pfds[0].events = POLLIN;
        pfds[1].fd = state.server;
        pfds[1].events = POLLIN;
        ready = poll(pfds, 2, -1);
        if (ready < 0) {
            wl_display_cancel_read(state.display);
            if (errno == EINTR) continue;
            break;
        }
        if (pfds[0].revents & POLLIN) wl_display_read_events(state.display);
        else wl_display_cancel_read(state.display);
        if (wl_display_dispatch_pending(state.display) < 0) break;
        if (state.blocked) break;
        if (pfds[1].revents & POLLIN) {
            int fd = accept4(state.server, NULL, NULL, SOCK_CLOEXEC);
            if (fd >= 0) {
                serve_client(fd);
                close(fd);
            }
        }
    }
}

static void cleanup_daemon(void) {
    // A blocked manager never owned the matrices. Destroying it can clear the
    // client that does, so only the owner destroys on the way out.
    if (state.ctm && !state.blocked) {
        hyprland_ctm_control_manager_v1_destroy(state.ctm);
        if (state.display) wl_display_flush(state.display);
    }
    state.ctm = NULL;
    if (state.server >= 0) {
        close(state.server);
        state.server = -1;
        if (socket_path[0]) unlink(socket_path);
    }
    if (state.display) {
        wl_display_disconnect(state.display);
        state.display = NULL;
    }
}

static void report_ready(int fd, int ok, const char *message) {
    char status = ok ? '1' : '0';
    if (fd < 0) return;
    if (write(fd, &status, 1) < 0) return;
    if (!ok && message) {
        size_t n = strlen(message);
        if (write(fd, message, n) < 0) return;
    }
}

static void detach_stdio(int keep) {
    int fd;
    int max = 256;
    for (fd = 3; fd < max; fd++) {
        if (fd != keep) close(fd);
    }
    fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > 2) close(fd);
    }
}

static int run_daemon(int ready_fd) {
    struct sigaction action;
    state.server = -1;
    state.gamma = 1.0;
    state.global_kelvin = 6500;
    if (!state.have_foreign) load_state();
    memset(&action, 0, sizeof action);
    action.sa_handler = on_signal;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    if (!connect_wayland()) {
        report_ready(ready_fd, 0, "could not bind color manager");
        cleanup_daemon();
        return 1;
    }
    state.ready = 1;
    if (state.have_foreign) {
        if (state.foreign_identity) set_all_identity(1);
        else set_all_temperature(state.foreign_kelvin);
    }
    else apply_all();
    state.server = listen_socket();
    if (state.server < 0) {
        report_ready(ready_fd, 0, "could not listen on hyprsunset socket");
        cleanup_daemon();
        return 1;
    }
    report_ready(ready_fd, 1, NULL);
    if (ready_fd >= 0) close(ready_fd);
    daemon_loop();
    cleanup_daemon();
    return 0;
}

static int ipc_exchange(const char *request, char *reply, size_t reply_len) {
    struct sockaddr_un address;
    int fd;
    struct pollfd pfd;
    ssize_t n;
    if (!socket_path[0]) return -1;
    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof address.sun_path, "%s", socket_path);
    if (connect(fd, (struct sockaddr *)&address, SUN_LEN(&address)) < 0) {
        close(fd);
        return -1;
    }
    if (send(fd, request, strlen(request), MSG_NOSIGNAL) < 0) {
        close(fd);
        return -1;
    }
    pfd.fd = fd;
    pfd.events = POLLIN;
    if (poll(&pfd, 1, 800) <= 0) {
        close(fd);
        return -1;
    }
    n = recv(fd, reply, reply_len - 1, 0);
    close(fd);
    if (n < 0) return -1;
    reply[n < 0 ? 0 : n] = '\0';
    return 0;
}

static int socket_is_ours(void) {
    char reply[REPLY_MAX];
    if (ipc_exchange("outputs", reply, sizeof reply) != 0) return 0;
    return reply[0] == '{';
}

static int exe_is_hyprsunset(pid_t pid) {
    char linkpath[64];
    char target[512];
    ssize_t n;
    snprintf(linkpath, sizeof linkpath, "/proc/%d/exe", (int)pid);
    n = readlink(linkpath, target, sizeof target - 1);
    if (n < 0) return 0;
    target[n] = '\0';
    return strcmp(target, "/usr/bin/hyprsunset") == 0 || strstr(target, "/hyprsunset") != NULL;
}

static void kill_foreign_hyprsunset(void) {
    DIR *dir = opendir("/proc");
    struct dirent *entry;
    if (!dir) return;
    while ((entry = readdir(dir))) {
        char commpath[64];
        char comm[32];
        int fd;
        ssize_t n;
        pid_t pid;
        char *end = NULL;
        if (!isdigit((unsigned char)entry->d_name[0])) continue;
        pid = (pid_t)strtol(entry->d_name, &end, 10);
        if (!end || *end || pid <= 0 || pid == getpid()) continue;
        snprintf(commpath, sizeof commpath, "/proc/%d/comm", (int)pid);
        fd = open(commpath, O_RDONLY);
        if (fd < 0) continue;
        n = read(fd, comm, sizeof comm - 1);
        close(fd);
        if (n <= 0) continue;
        comm[n] = '\0';
        if (comm[n - 1] == '\n') comm[n - 1] = '\0';
        if (strcmp(comm, "hyprsunset") != 0) continue;
        if (!exe_is_hyprsunset(pid)) continue;
        kill(pid, SIGTERM);
    }
    closedir(dir);
}

static int foreign_gone(void) {
    char reply[64];
    if (ipc_exchange("temperature", reply, sizeof reply) != 0) return 1;
    if (reply[0] == '{') return 1;
    return 0;
}

// Returns -1 when a foreign hyprsunset is still holding the color manager.
static int snapshot_foreign(void) {
    char temperature[64];
    char identity[64];
    char *end = NULL;
    long long kelvin;
    int i;
    state.have_foreign = 0;
    if (ipc_exchange("temperature", temperature, sizeof temperature) != 0) return 0;
    if (temperature[0] == '{') return 0;
    if (ipc_exchange("identity get", identity, sizeof identity) != 0) identity[0] = '\0';
    kelvin = strtoll(temperature, &end, 10);
    if (!end || end == temperature) return 0;
    state.have_foreign = 1;
    state.foreign_kelvin = clamp_kelvin(kelvin);
    state.foreign_identity = strncmp(identity, "true", 4) == 0;
    kill_foreign_hyprsunset();
    for (i = 0; i < 40 && !foreign_gone(); i++) usleep(50 * 1000);
    if (!foreign_gone()) {
        state.have_foreign = 0;
        fprintf(stderr, "sunset-ctm: hyprsunset is still running\n");
        return -1;
    }
    if (socket_path[0]) unlink(socket_path);
    return 0;
}

static int start_daemon(void) {
    int ready_pipe[2];
    pid_t pid;
    char status = 0;
    char message[256];
    ssize_t n;
    if (!socket_path[0]) {
        fprintf(stderr, "sunset-ctm: no Hyprland session\n");
        return -1;
    }
    if (socket_is_ours()) return 0;
    if (snapshot_foreign() != 0) return -1;
    if (socket_is_ours()) return 0;
    if (pipe(ready_pipe) < 0) return -1;
    pid = fork();
    if (pid < 0) {
        close(ready_pipe[0]);
        close(ready_pipe[1]);
        return -1;
    }
    if (pid == 0) {
        close(ready_pipe[0]);
        if (setsid() < 0) {
            report_ready(ready_pipe[1], 0, "setsid failed");
            _exit(1);
        }
        detach_stdio(ready_pipe[1]);
        _exit(run_daemon(ready_pipe[1]));
    }
    close(ready_pipe[1]);
    n = read(ready_pipe[0], &status, 1);
    message[0] = '\0';
    if (n == 1 && status != '1') {
        ssize_t got = read(ready_pipe[0], message, sizeof message - 1);
        if (got < 0) got = 0;
        message[got] = '\0';
    }
    close(ready_pipe[0]);
    if (n == 1 && status == '1') return 0;
    for (int attempt = 0; attempt < 20; attempt++) {
        if (socket_is_ours()) return 0;
        usleep(50 * 1000);
    }
    if (message[0]) fprintf(stderr, "sunset-ctm: %s\n", message);
    return -1;
}

static int forward_request(const char *request) {
    char reply[REPLY_MAX];
    if (start_daemon() != 0) return 1;
    if (ipc_exchange(request, reply, sizeof reply) != 0) {
        fprintf(stderr, "sunset-ctm: no reply\n");
        return 1;
    }
    printf("%s\n", reply);
    return strncmp(reply, "invalid", 7) == 0 || strncmp(reply, "unknown", 7) == 0 || strncmp(reply, "Invalid", 7) == 0;
}

static int join_args(int argc, char **argv, char *out, size_t out_len) {
    size_t used = 0;
    int i;
    out[0] = '\0';
    for (i = 1; i < argc; i++) {
        size_t n = strlen(argv[i]);
        if (used && used + 1 < out_len) out[used++] = ' ';
        if (used + n >= out_len) return -1;
        memcpy(out + used, argv[i], n);
        used += n;
        out[used] = '\0';
    }
    return 0;
}

static int self_test(void) {
    double warm[9];
    double day[9];
    double ember[9];
    unsigned kelvin = 0;
    char request[128];
    char reply[REPLY_MAX];
    matrix_for_kelvin(4000, 1.0, warm);
    matrix_for_kelvin(6500, 1.0, day);
    matrix_for_kelvin(2000, 1.0, ember);
    if (fabs(warm[0] - 1.0) > 1e-6 || fabs(warm[4] - 0.80712247756) > 1e-6 || fabs(warm[8] - 0.65129941968) > 1e-6) return 1;
    if (fabs(day[4] - 0.99651013285) > 1e-6 || fabs(ember[4] - 0.53673853105) > 1e-6) return 1;
    if (warm[1] != 0 || warm[2] != 0 || warm[3] != 0) return 1;
    if (!valid_name("eDP-1") || !valid_name("DP-3") || !valid_name("HDMI-A-1")) return 1;
    if (valid_name("-DP-1") || valid_name("eDP 1") || valid_name("bad;name") || valid_name("")) return 1;
    if (!parse_kelvin_arg("4000", 6500, &kelvin) || kelvin != 4000) return 1;
    if (!parse_kelvin_arg("+100", 4000, &kelvin) || kelvin != 4100) return 1;
    if (!parse_kelvin_arg("-500", 4000, &kelvin) || kelvin != 3500) return 1;
    if (!parse_kelvin_arg("10", 4000, &kelvin) || kelvin != 1000) return 1;
    if (parse_kelvin_arg("12K", 4000, &kelvin)) return 1;

    state.gamma = 1;
    state.global_kelvin = 6500;
    state.ready = 1;
    state.outputs[0].used = 1;
    state.outputs[0].named = 1;
    snprintf(state.outputs[0].name, sizeof state.outputs[0].name, "eDP-1");
    state.outputs[1].used = 1;
    state.outputs[1].named = 1;
    snprintf(state.outputs[1].name, sizeof state.outputs[1].name, "DP-3");
    find_desired("eDP-1", 1)->kelvin = 3200;
    find_desired("eDP-1", 0)->identity = 0;
    find_desired("DP-3", 1)->identity = 1;
    if (representative_kelvin() != 3200) return 1;
    if (all_identity()) return 1;
    snprintf(request, sizeof request, "output DP-3 temperature 4500");
    handle_request(request, reply, sizeof reply);
    if (strcmp(reply, "ok") != 0) return 1;
    if (find_desired("DP-3", 0)->identity || find_desired("DP-3", 0)->kelvin != 4500) return 1;
    if (find_desired("eDP-1", 0)->kelvin != 3200) return 1;
    snprintf(request, sizeof request, "output nope temperature 3000");
    handle_request(request, reply, sizeof reply);
    if (strcmp(reply, "unknown output") != 0) return 1;
    snprintf(request, sizeof request, "output bad;name temperature 3000");
    handle_request(request, reply, sizeof reply);
    if (strcmp(reply, "invalid output") != 0) return 1;
    reply_outputs(reply, sizeof reply);
    if (!strstr(reply, "\"name\":\"eDP-1\"") || !strstr(reply, "\"kelvin\":3200") || !strstr(reply, "\"name\":\"DP-3\"")) return 1;
    printf("ok\n");
    return 0;
}

int main(int argc, char **argv) {
    char request[1024];
    runtime_paths();
    state.server = -1;
    state.gamma = 1.0;
    state.global_kelvin = 6500;
    if (argc >= 2 && strcmp(argv[1], "--self-test") == 0) return self_test();
    if (argc == 2 && strcmp(argv[1], "stop") == 0) argv[1] = "quit";
    if (argc >= 2 && strcmp(argv[1], "--daemon") == 0) {
        detach_stdio(-1);
        return run_daemon(-1);
    }
    if (argc < 2) return start_daemon() == 0 ? 0 : 1;
    if (join_args(argc, argv, request, sizeof request) != 0) return 1;
    return forward_request(request);
}
