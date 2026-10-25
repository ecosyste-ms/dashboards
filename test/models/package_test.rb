require 'test_helper'

class PackageTest < ActiveSupport::TestCase
  test "order_by_rankings sorts by average ranking ascending with nulls last" do
    project = create(:project)
    
    # Create packages with different rankings
    pkg_with_null = create(:package, project: project, name: "no-ranking", metadata: {})
    pkg_with_high_ranking = create(:package, project: project, name: "high-ranking", 
                                  metadata: { "rankings" => { "average" => "0.85" } })
    pkg_with_low_ranking = create(:package, project: project, name: "low-ranking", 
                                 metadata: { "rankings" => { "average" => "0.15" } })
    
    ordered_packages = Package.order_by_rankings.to_a
    
    # Should be ordered: low ranking (0.15), high ranking (0.85), null ranking
    low_index = ordered_packages.index(pkg_with_low_ranking)
    high_index = ordered_packages.index(pkg_with_high_ranking)  
    null_index = ordered_packages.index(pkg_with_null)
    
    assert low_index < high_index, "Low ranking package should come before high ranking package"
    assert high_index < null_index, "Packages with rankings should come before packages without rankings"
  end

  test "purl_without_version drops the julia uuid qualifier" do
    assert_equal "pkg:julia/Dates", Package.purl_without_version("pkg:julia/Dates@1.9.0?uuid=ade2ca70-3891-5945-98fb-dc099432e06a")
    assert_equal "pkg:deb/debian/curl?arch=amd64", Package.purl_without_version("pkg:deb/debian/curl@7.0?arch=amd64")
  end

  test "package_url matches julia packages with or without the uuid qualifier" do
    package = create(:package, ecosystem: "julia", name: "Dates", purl: "pkg:julia/Dates")

    assert_equal [package], Package.package_url("pkg:julia/Dates").to_a
    assert_equal [package], Package.package_url("pkg:julia/Dates?uuid=ade2ca70-3891-5945-98fb-dc099432e06a").to_a
  end
end
