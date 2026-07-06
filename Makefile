.PHONY: all test clean

all: test

test:
	[ -d test/lib ] || (mkdir -p test/lib test/logs; mvn dependency:copy-dependencies -DoutputDirectory=test/lib)
	JULIA_NUM_THREADS=4 julia test/test.jl

clean:
	rm -rf test/lib test/logs
