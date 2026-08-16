KDIR := $(KDIR)
MDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

$(info -- KDIR: $(KDIR))
$(info -- MDIR: $(MDIR))

.PHONY: all clean format

all:
	make -C $(KDIR) M=$(MDIR) modules -j$(shell nproc)

clean:
	make -C $(KDIR) M=$(MDIR) clean

format:
	find . \( -name "*.c" -o -name "*.h" \) -print0 | xargs -0 clang-format -i

# Keep a new line here!! Because someone may append config
