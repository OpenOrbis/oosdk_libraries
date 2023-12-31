# Check for linux vs macOS and account for clang/ld path
UNAME_S     := $(shell uname -s)

ifeq ($(UNAME_S),Linux)
		CC      := clang
		CXX     := clang++
		LD      := ld.lld
		AR      := llvm-ar
		CDIR    := linux
endif
ifeq ($(UNAME_S),Darwin)
		CC      := /usr/local/opt/llvm/bin/clang
		CXX     := /usr/local/opt/llvm/bin/clang++
		LD      := /usr/local/opt/llvm/bin/ld.lld
		AR      := /usr/local/opt/llvm/bin/llvm-ar
		CDIR    := macos
endif

# Allow for 'make VERBOSE=1' to see the recepie executions
ifndef VERBOSE
  VERB := @
endif

#---------------------------------------------------------------------------------
%.a:
#---------------------------------------------------------------------------------
	$(VERB) echo $(notdir $@)
	$(VERB) rm -f $@
	$(VERB) $(AR) -rc $@ $^

#---------------------------------------------------------------------------------
%.elf: $(OFILES)
	$(VERB) echo linking ... $(notdir $@)
	$(VERB) $(LD)  $^ $(LDFLAGS) $(LIBPATHS) $(LIBS) -o $@

#---------------------------------------------------------------------------------
%.o: %.cpp
	$(VERB) echo $(notdir $<)
	$(VERB) $(CXX) $(DEPSOPT) $(CXXFLAGS) -o $@ $< $(ERROR_FILTER)

#---------------------------------------------------------------------------------
%.o: %.c
	$(VERB) echo $(notdir $<)
	$(VERB) $(CC) $(DEPSOPT) $(CFLAGS) -o $@ $< $(ERROR_FILTER)

#---------------------------------------------------------------------------------
%.o: %.m
	$(VERB) echo $(notdir $<)
	$(VERB) $(CC) $(DEPSOPT) $(OBJCFLAGS) -o $@ $< $(ERROR_FILTER)

#---------------------------------------------------------------------------------
%.o: %.s
	$(VERB) echo $(notdir $<)
	$(VERB) $(CC) $(DEPSOPT) -x assembler-with-cpp $(ASFLAGS) -o $@ $< $(ERROR_FILTER)

#---------------------------------------------------------------------------------
%.o: %.S
	$(VERB) echo $(notdir $<)
	$(VERB) $(CC) $(DEPSOPT) -x assembler-with-cpp $(ASFLAGS) -o $@ $< $(ERROR_FILTER)

#---------------------------------------------------------------------------------
# canned command sequence for binary data
#---------------------------------------------------------------------------------
define bin2o
	$(VERB) bin2s -a 64 $< | $(AS) -o $(@)
	$(VERB) echo "extern const u8" `(echo $(<F) | sed -e 's/^\([0-9]\)/_\1/' | tr . _)`"_end[];" > `(echo $(<F) | tr . _)`.h
	$(VERB) echo "extern const u8" `(echo $(<F) | sed -e 's/^\([0-9]\)/_\1/' | tr . _)`"[];" >> `(echo $(<F) | tr . _)`.h
	$(VERB) echo "extern const u32" `(echo $(<F) | sed -e 's/^\([0-9]\)/_\1/' | tr . _)`_size";" >> `(echo $(<F) | tr . _)`.h
endef
