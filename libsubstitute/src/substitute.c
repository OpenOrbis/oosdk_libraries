#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include <orbis/libkernel.h>

#include "substitute.h"

struct substitute_hook* substitute_hook(const char* module_name, const char* name, void* hook_function, int flags) {
  if (strlen(module_name) > SUBSTITUTE_MAX_NAME) {
    printf("libsubstitute -> mira_hook_iat(module_name): SUBSTITUTE_MAX_NAME reached.\n");
    return NULL;
  }

  if (strlen(name) > SUBSTITUTE_MAX_NAME) {
    printf("libsubstitute -> mira_hook_iat(name): SUBSTITUTE_MAX_NAME reached.\n");
    return NULL;
  }

  // Setup chain & information system
  struct substitute_hook* hook = (struct substitute_hook*)malloc(sizeof(struct substitute_hook));

  if (!hook) {
    printf("libsubstitute -> mira_hook_iat: unable to malloc mira_hook structure !\n");
    return NULL;
  }

  memset(hook, 0, sizeof(struct substitute_hook));

  // Call mira hook system
  int mira_device = open("/dev/mira", O_RDWR);
  if (mira_device < 0) {
    printf("libsubstitute -> mira_hook_iat: can't open mira device (%d).\n", mira_device);
    return NULL;
  }

  // Setup parameter
  struct substitute_hook_iat param;
  param.hook_id = -1; // Pre-set for prevent to get 0 if something append

  param.hook_function = hook_function;
  param.flags = flags;
  param.chain = hook;
  strncpy(param.name, name, SUBSTITUTE_MAX_NAME);
  strncpy(param.module_name, module_name, SUBSTITUTE_MAX_NAME);

  // Do ioctl
  int ret = ioctl(mira_device, MIRA_IOCTL_IAT_HOOK, &param);

  if (ret != 0) {
    printf("libsubstitute -> mira_hook_iat: ioctl error (%d).\n", ret);
    free(hook);
    return NULL;
  }

  close(mira_device);

  // Check returned data
  if (param.hook_id < 0) {
    printf("libsubstitute -> mira_hook_iat: data returned is invalid !\n");
    free(hook);
    return NULL;
  }

  printf("libsubstitute -> new hook iat !\nhook_id: %i\nchain_structure: %p\n", param.hook_id, param.chain);
  return hook;
}

int substitute_statehook(struct substitute_hook* hook, int state) {
  if (!hook) {
    printf("libsubstitute -> mira_hook_iat: invalid parameter.\n");
    return 1;
  }

  // Call mira hook system
  int mira_device = open("/dev/mira", O_RDWR);
  if (mira_device < 0) {
    printf("libsubstitute -> mira_hook_iat: can't open mira device (%d).\n", mira_device);
    return 1;
  }

  // Setup parameter
  struct substitute_state_hook param;
  param.hook_id = hook->hook_id;
  param.state = state;
  param.chain = hook;

  // Do ioctl
  int ret = ioctl(mira_device, MIRA_IOCTL_STATE_HOOK, &param);
  close(mira_device);

  if (ret < 0) {
    printf("libsubstitute -> mira_state_hook: ioctl error (%d).\n", ret);
    return 1;
  }

  // Close device
  close(mira_device);

  // Check returned data
  if (param.result < 0) {
    printf("libsubstitute -> mira_hook_iat: data returned is invalid (ret: %d) !\n", param.result);
    return 1;
  }

  return 0;
}

int substitute_disable(struct substitute_hook* hook) {
  return substitute_statehook(hook, SUBSTITUTE_STATE_DISABLE);
}

int substitute_enable(struct substitute_hook* hook) {
  return substitute_statehook(hook, SUBSTITUTE_STATE_ENABLE);
}

int substitute_unhook(struct substitute_hook* hook) {
  return substitute_statehook(hook, SUBSTITUTE_STATE_UNHOOK);
}
