package calc

import "testing"

func TestAdd(t *testing.T) {
	tests := []struct {
		name string
		a    int
		b    int
		want int
	}{
		{name: "positive", a: 2, b: 3, want: 5},
		{name: "negative", a: -2, b: -3, want: -5},
		{name: "mixed positive sum", a: -2, b: 5, want: 3},
		{name: "mixed negative sum", a: 2, b: -5, want: -3},
		{name: "canceling", a: -4, b: 4, want: 0},
		{name: "zero left", a: 0, b: 7, want: 7},
		{name: "zero right", a: -7, b: 0, want: -7},
		{name: "both zero", a: 0, b: 0, want: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Add(tt.a, tt.b); got != tt.want {
				t.Errorf("Add(%d, %d) = %d, want %d", tt.a, tt.b, got, tt.want)
			}
		})
	}
}
