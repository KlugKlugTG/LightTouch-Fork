// Exercise the production AFC transfer with mocked guest responses; no device or emulator is contacted.
#define lockdownd_start_service test_start_service
#define lockdownd_service_descriptor_free test_service_free
#define afc_client_new test_afc_new
#define afc_client_free test_afc_free
#define afc_get_device_info_key test_device_info
#define afc_make_directory test_mkdir
#define afc_file_open test_open
#define afc_file_write test_write
#define afc_file_read test_read
#define afc_file_close test_close
#define afc_get_file_info test_file_info
#define afc_rename_path test_rename
#define afc_remove_path test_remove
#define afc_read_directory test_directory
#define main appservice_main
#include "../lt_appservice.c"
#undef main
#include <assert.h>

static unsigned char *received;
static size_t received_size;
static char staging[256], saved[256];
static int published, removed, zero_write, short_stat, rename_error;
static uint64_t space = 1ull << 30;
static int root_service, missing_worker;
static const char *read_text;
static size_t read_offset;
static char opened_report[256];

lockdownd_error_t test_start_service(lockdownd_client_t client, const char *name, lockdownd_service_descriptor_t *service)
{
	assert(!strcmp(name, AFC_SERVICE_NAME) || !strcmp(name, "com.apple.afc2") || !strcmp(name, "com.apple.crashreportcopymobile"));
	root_service = !strcmp(name, "com.apple.afc2");
	*service = calloc(1, sizeof(**service));
	return LOCKDOWN_E_SUCCESS;
}
lockdownd_error_t test_service_free(lockdownd_service_descriptor_t service) { free(service); return LOCKDOWN_E_SUCCESS; }
afc_error_t test_afc_new(idevice_t device, lockdownd_service_descriptor_t service, afc_client_t *client)
{ *client = (afc_client_t)(uintptr_t)1; return AFC_E_SUCCESS; }
afc_error_t test_afc_free(afc_client_t client) { return AFC_E_SUCCESS; }
afc_error_t test_device_info(afc_client_t client, const char *key, char **value)
{ assert(!strcmp(key, "FSFreeBytes")); assert(asprintf(value, "%" PRIu64, space) > 0); return AFC_E_SUCCESS; }
afc_error_t test_mkdir(afc_client_t client, const char *path)
{ assert(!strcmp(path, "Un1box") || !strcmp(path, DEB_DIR)); return AFC_E_OBJECT_EXISTS; }
afc_error_t test_open(afc_client_t client, const char *path, afc_file_mode_t mode, uint64_t *handle)
{
	if (root_service) {
		if (mode == AFC_FOPEN_RDONLY) { read_offset = 0; *handle = 2; snprintf(opened_report, sizeof opened_report, "%s", path); return AFC_E_SUCCESS; }
		assert(strstr(path, INSTALL_BASE "/.") == path); strcpy(staging, path); *handle = 1;
		free(received); received = NULL; received_size = 0; return AFC_E_SUCCESS;
	}
	assert(strstr(path, DEB_DIR "/.") == path && strstr(path, ".upload"));
	assert(mode == AFC_FOPEN_WRONLY); strcpy(staging, path); *handle = 1;
	return AFC_E_SUCCESS;
}
afc_error_t test_read(afc_client_t client, uint64_t handle, char *bytes, uint32_t length, uint32_t *got)
{
	assert(root_service && handle == 2);
	size_t left = read_text ? strlen(read_text) - read_offset : 0;
	*got = left > length ? length : (uint32_t)left;
	if (*got) memcpy(bytes, read_text + read_offset, *got);
	read_offset += *got; return AFC_E_SUCCESS;
}
afc_error_t test_write(afc_client_t client, uint64_t handle, const char *bytes, uint32_t length, uint32_t *written)
{
	*written = zero_write ? 0 : (length > 8191 ? 8191 : length);
	received = realloc(received, received_size + *written + 1);
	assert(received); memcpy(received + received_size, bytes, *written); received_size += *written;
	return AFC_E_SUCCESS;
}
afc_error_t test_close(afc_client_t client, uint64_t handle) { return AFC_E_SUCCESS; }
afc_error_t test_file_info(afc_client_t client, const char *path, char ***info)
{
	if (missing_worker && !strcmp(path, "/usr/libexec/un1box-deb-install")) return AFC_E_OBJECT_NOT_FOUND;
	*info = calloc(5, sizeof(char *)); assert(*info);
	(*info)[0] = strdup("st_ifmt"); (*info)[1] = strdup("S_IFREG"); (*info)[2] = strdup("st_size");
	assert(asprintf(&(*info)[3], "%zu", received_size - (short_stat && received_size ? 1 : 0)) > 0);
	return AFC_E_SUCCESS;
}
afc_error_t test_rename(afc_client_t client, const char *from, const char *to)
{
	assert(!strcmp(from, staging));
	if (root_service) assert(strstr(to, INSTALL_BASE "/InstallQueue/") == to);
	else { assert(strstr(to, DEB_DIR "/") == to); assert(deb_name_valid(to + strlen(DEB_DIR) + 1)); }
	if (rename_error) return AFC_E_IO_ERROR;
	strcpy(saved, to); published++; return AFC_E_SUCCESS;
}
afc_error_t test_remove(afc_client_t client, const char *path)
{ assert(!strcmp(path, staging)); removed++; return AFC_E_SUCCESS; }
afc_error_t test_directory(afc_client_t client, const char *path, char ***names)
{
	if (!strcmp(path, "/")) { *names = calloc(1, sizeof(char *)); return AFC_E_SUCCESS; }
	if (!strcmp(path, "/Library/Logs/CrashReporter")) {
		*names = calloc(4, sizeof(char *));
		(*names)[0] = strdup("iFile5-2026-10-25-123552.plist");
		(*names)[1] = strdup("Cydia-2026-10-25-123527.plist");
		(*names)[2] = strdup("LatestCrash.plist");
		return AFC_E_SUCCESS;
	}
	assert(!strcmp(path, DEB_DIR));
	*names = calloc(5, sizeof(char *)); assert(*names);
	(*names)[0] = strdup("."); (*names)[1] = strdup(".."); (*names)[2] = strdup(".interrupted.upload");
	(*names)[3] = strdup("own-package.deb");
	return AFC_E_SUCCESS;
}

static void reset(void)
{
	free(received); received = NULL; received_size = 0;
	published = removed = zero_write = short_stat = rename_error = 0;
	space = 1ull << 30; staging[0] = saved[0] = 0;
	root_service = missing_worker = 0; read_text = NULL;
}

int main(void)
{
	assert(!strcmp(crash_report_date("iFile5-2026-10-25-123552.plist"), "2026-10-25-123552.plist"));
	assert(!strcmp(crash_report_date("Example_2026-10-25-123552_phone.ips"), "2026-10-25-123552_phone.ips"));
	assert(crash_report_date("LatestCrash.plist") == NULL);
	assert(install_token_valid("0123456789abcdef0123456789abcdef"));
	assert(!install_token_valid("../0123456789abcdef0123456789abcd"));
	assert(!install_token_valid("0123456789abcdef0123456789abcdeF"));
	assert(!install_token_valid(""));
	assert(deb_name_valid("own-package.deb"));
	assert(!deb_name_valid("../own-package.deb")); assert(!deb_name_valid(".hidden.deb"));
	assert(!deb_name_valid("other/path.deb")); assert(!deb_name_valid("not-a-package.ipa"));
	char source[] = "/tmp/un1box-deb-test-XXXXXX";
	int fd = mkstemp(source); assert(fd >= 0);
	size_t length = UPLOAD_CHUNK + 37;
	unsigned char *bytes = malloc(length); assert(bytes);
	for (size_t i = 0; i < length; i++) bytes[i] = (unsigned char)i;
	memcpy(bytes, "!<arch>\n", 8);
	assert(write(fd, bytes, length) == (ssize_t)length); close(fd);
	struct session session = {0};
	reset(); assert(action_upload_deb(&session, source, "own-package.deb") == 0);
	assert(published == 1 && removed == 0 && received_size == length && !memcmp(received, bytes, length));
	char first[256]; strcpy(first, saved);
	reset(); assert(action_upload_deb(&session, source, "own-package.deb") == 0); assert(strcmp(first, saved));
	assert(action_deb_list(&session) == 0);
	reset(); zero_write = 1; assert(action_upload_deb(&session, source, "own-package.deb") == 1); assert(!published && removed == 1);
	reset(); short_stat = 1; assert(action_upload_deb(&session, source, "own-package.deb") == 1); assert(!published && removed == 1);
	reset(); rename_error = 1; assert(action_upload_deb(&session, source, "own-package.deb") == 1); assert(!published && removed == 1);
	reset(); space = 0; assert(action_upload_deb(&session, source, "own-package.deb") == 1); assert(!published && !received_size);
	unlink(source); free(bytes); reset();
	const char *token = "0123456789abcdef0123456789abcdef";
	received_size = 8; assert(action_deb_queue(&session, "own-package.deb", token) == 0);
	assert(published == 1 && received_size == strlen("own-package.deb\n") && !memcmp(received, "own-package.deb\n", received_size));
	reset(); received_size = 8; zero_write = 1; assert(action_deb_queue(&session, "own-package.deb", token) == 1); assert(!published && removed == 1);
	reset(); missing_worker = 1; assert(action_deb_state(&session, "deb-probe", NULL) == 1); assert(!published);
	reset(); assert(action_deb_state(&session, "deb-probe", NULL) == 0);
	read_text = "Package: example\nStatus: install ok installed\nVersion: 1.0\n";
	assert(action_deb_state(&session, "deb-installed", NULL) == 0);
	read_text = "installed\n"; assert(action_deb_state(&session, "deb-status", token) == 0);
	reset(); read_text = "<plist><string>launch watchdog</string></plist>";
	assert(action_crashlog(&session) == 0);
	assert(!strcmp(opened_report, "/Library/Logs/CrashReporter/iFile5-2026-10-25-123552.plist"));
	reset();
	fprintf(stderr, "PASS: partial AFC writes, copied bytes, unique names, hidden partials, zero writes, incomplete stat, rename error and low space.\n");
	return 0;
}
