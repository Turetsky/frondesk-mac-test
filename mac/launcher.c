// Frondesk.app main executable: hands over to Contents/Resources/open.sh (signed with the app).
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
  char exe[PATH_MAX], sh[PATH_MAX];
  uint32_t n = sizeof exe;
  if (_NSGetExecutablePath(exe, &n) != 0) return 1;
  snprintf(sh, sizeof sh, "%s/../Resources/open.sh", dirname(exe));
  execl("/bin/sh", "sh", sh, (char *)0);
  return 127;
}
