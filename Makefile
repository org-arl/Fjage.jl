.PHONY: all test clean

all: test

test:
	[ -d test/lib ] || (mkdir -p test/lib test/logs; mvn dependency:copy-dependencies -DoutputDirectory=test/lib)
	julia test/test.jl

clean:
	rm -rf test/lib test/logs
