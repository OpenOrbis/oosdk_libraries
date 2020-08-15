# substitute
libsusbtitute is the userland implementation for Mira Substitute system.

Ported to OOSDK for PS4 by TheoryWrong on 8/15/2020

## Notes 
	- please use the oosdk_build.bat to build and install libsubstitute to oosdk.
	- to link with libsubstitute, open your build.bat and add to libraries list -lsubstitute
	
## OOSDK Todo
	- Create sample to compile for oosdk (Sample will be done soon)

## Installation 
The installation is done automatically by the build script

## Usage
For hook a SCE Function, you need to use
```c
struct substitute_hook* substitute_hook(const char* module_name, const char* name, void* hook_function, int flags);
```
The default module_name is SUBSTITUTE_MAIN_MODULE (it's simply the eboot/main program), but you can hook function from another module

For flags, 2 exist :
- SUBSTITUTE_IAT_NAME : Use the original name (like `sceUserServiceGetUserName`)
- SUBSTITUTE_IAT_NIDS : Use the nids as name (like `1xxcMiGu2fo`)

Return NULL if a error occurs.

Example :
```c
struct substitute_hook* username_hook;

void sceUserServiceGetUserName_hook(uint64_t userId, char *userName, const size_t size) {
	SUBSTITUTE_WAIT(username_hook); // Wait for the hook object

	SUBSTITUTE_CONTINUE(void, username_hook, (uint64_t, char*, const size_t), userId, userName, size); // Call the original function, with original argument

	printf("The username is: %s", userName); // Show the original username
	strncpy(userName, "mycustomname", 12); // Inject a custom username instead
}

...

int module_start() {
	username_hook = substitute_hook(SUBSTITUTE_MAIN_MODULE, "sceUserServiceGetUserName", sceUserServiceGetUserName_hook, SUBSTITUTE_IAT_NAME);
	if (!username_hook) {
		printf("Unable to hook username function.\n");
	}

	return 0;
}

```

Some explaination of macro here:
`SUBSTITUTE_WAIT(hook)` is a macro for check when the hook object is available
`SUBSTITUTE_CONTINUE(type, hook, argl, ...)` is a macro for call the original function. If you don't need it, don't call him.

When you are done with the hook, you can delete it by using `substitute_unhook`.
Return 0 when everything is ok.

```c
struct substitute_hook* username_hook;

...

int module_stop() {
	if (substitute_unhook(username_hook) > 0) {
		printf("Unable to unhook the username hook\n");
	}

	return 0;
}
```

You can also simply disable/enable a hook for a moment by `substitute_disable` and `substitute_enable`
```c
int substitute_disable(struct substitute_hook* hook);
int substitute_enable(struct substitute_hook* hook);
```

## Note

You need to got the last version of Mira.
For install the plugin inside the console, use the FTP or any other File Manager.
The folder structure need to respect this case (For example with game CUSA00001 "The Playroom")

`/data/mira/substitute/CUSA00001/ThePlugin.sprx`

The plugin is launched automatically during the load of the game and before this entrypoint.
