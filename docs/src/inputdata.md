# Input Data Format

C4's data model represents power system resources in three broad classes: _variable_ generating units, _thermal_ generating units, and _storage_ units. Within these classes, it futher differentiates between _candidate_ resources (which require both capital investment and operating data) and _existing_ resources (which only require operating data). Finally, these broad classes are populated by individual _technologies_, each of which can exist at multiple different _sites_. Data are specified in relation to a specific site or technology.

Site and technology properties are represented in one of three ways based on their evolution (or not) across time. Some properties are _static_, meaning they don't change across time, and are defined directly in relation to a technology or site. Other properties change across investment periods, but are static within a single period. Finally, properties can change across operating periods (i.e. hourly).

```@raw html
<div id="datatree">
<ul><li id="datatree-root">/<ul>
    <li class="file">
        demand.csv
        <span class="note">operating periods</span>
    </li>
    <li class="folder">
        fuel
        <ul>
            <li class="file">
                fuels.csv
                <ul>
                    <li class="id">fuel</li>
                    <li>co2_factor</li>
                </ul>
            </li>
            <li class="file">
                fuel_cost.csv
                <span class="note">investment periods</span>
            </li>
        </ul>
    </li>
    <li class="folder">
        thermal
        <ul>
            <li class="folder">
                existing
                <ul>
                    <li class="file">
                        techs.csv
                        <ul>
                            <li class="id">tech</li>
                            <li>category</li>
                            <li>fuel</li>
                            <li>heat_rate</li>
                            <li>startup_heat</li>
                            <li>unit_size</li>
                            <li>min_gen</li>
                            <li>max_ramp</li>
                            <li>min_uptime</li>
                            <li>min_downtime</li>
                        </ul>
                    <li class="file">
                        tech_rating.csv
                        <span class="note">operating periods</span>
                    </li>
                    <li class="file">
                        tech_cost_fom.csv
                        <span class="note">investment periods</span>
                    </li>
                    <li class="file">
                        tech_cost_vom.csv
                        <span class="note">investment periods</span>
                    </li>
                    <li class="file">
                        sites.csv
                        <ul>
                            <li>tech</li>
                            <li class="id">site</li>
                        </ul>
                    <li class="file">
                        site_units.csv
                        <span class="note">investment periods</span>
                    </li>
                    <li class="file">
                        site_mttf.csv
                        <span class="note">operating periods</span>
                    </li>
                    <li class="file">
                        site_mttr.csv
                        <span class="note">operating periods</span>
                    </li>
                </ul>
            </li>
            <li class="folder">
                candidate
                <ul>
                    <li class="file">
                        techs.csv
                        <ul>
                            <li class="id">tech</li>
                            <li>category</li>
                            <li>fuel</li>
                            <li>heat_rate</li>
                            <li>startup_heat</li>
                            <li>unit_size</li>
                            <li>min_gen</li>
                            <li>max_ramp</li>
                            <li>min_uptime</li>
                            <li>min_downtime</li>
                        </ul>
                    <li class="file">
                        tech_max_units.csv
                        <span class="note">investment periods</span>
                    </li>
                    <li class="file">
                        tech_rating.csv
                        <span class="note">operating periods</span>
                    </li>
                    <li class="file">
                        tech_mttf.csv
                        <span class="note">operating periods</span>
                    </li>
                    <li class="file">
                        tech_mttr.csv
                        <span class="note">operating periods</span>
                    </li>
                    <li class="file">
                        tech_cost_capital.csv
                        <span class="note">investment periods</span>
                    </li>
                    <li class="file">
                        tech_cost_fom.csv
                        <span class="note">investment periods</span>
                    </li>
                    <li class="file">
                        tech_cost_vom.csv
                        <span class="note">investment periods</span>
                    </li>
                </ul>
            </li>
        </ul>
    </li>
    <li class="folder">
        ...
    </li>
</ul>
</div>
```
